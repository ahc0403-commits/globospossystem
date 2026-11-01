import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/emergency_web_bridge.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/kds_progress_journal.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

class _Store extends KdsOutboxStore {
  final records = <String, EmergencyOutboxRecord>{};
  final failBefore = <int>{};
  final failAfter = <int>{};
  var puts = 0;
  bool unreadable = false;
  bool cannotDelete = false;

  @override
  Future<void> put(String id, String payload) async {
    puts++;
    if (failBefore.contains(puts)) throw StateError('storage unavailable');
    records[id] = EmergencyOutboxRecord(id: id, payload: payload);
    if (failAfter.contains(puts)) throw StateError('acknowledgement lost');
  }

  @override
  Future<List<EmergencyOutboxRecord>> read() async {
    if (unreadable) throw StateError('storage unreadable');
    return records.values.toList(growable: false);
  }

  @override
  Future<void> delete(String id) async {
    if (cannotDelete) throw StateError('delete unavailable');
    records.remove(id);
  }
}

class _Notifier extends EmergencyFulfillmentNotifier {
  _Notifier(
    SupabaseClient client,
    KdsOutboxStore store, {
    bool authenticated = true,
  }) : super(
         client: client,
         outbox: store,
         enableRealtimeSubscriptions: false,
         actorIdForTesting: authenticated ? () => 'fixture-auth' : null,
       ) {
    seed('store-1');
  }
  void seed(String store, {String station = 'floor'}) =>
      state = EmergencyFulfillmentState.fromJson({
        'active': true,
        'assigned': true,
        'restaurant_id': store,
        'session_id': 'session-1',
        'station_type': station,
        'floor_label': '1F',
        'orders': [
          {
            'queue_id': 'queue-1',
            'order_id': 'order-1',
            'queue_no': 1,
            'table_number': '101',
            'floor_label': '1F',
            'workflow_version': 2,
            'created_at': '2026-11-01T01:00:00Z',
            'items': [
              {
                'id': 'item-1',
                'order_item_id': 'line-1',
                'ordered_quantity': 2,
                'kitchen_started_quantity': 2,
                'kitchen_done_quantity': 1,
                'tray_received_quantity': 1,
                'tray_dispatched_quantity': 1,
                'floor_served_quantity': 0,
                'workflow_version': 2,
                'kitchen_direct_to_floor': true,
              },
            ],
          },
        ],
      });
}

http.Response _json(Object data, {int status = 200}) => http.Response(
  jsonEncode(data),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> _payload(String id) => {
  'event_id': id,
  'item_id': 'item-1',
  'queue_id': 'queue-1',
  'stage': 'floor_served',
  'delta': 1,
  'workflow_v2': true,
  'floor_direct': false,
  'combo_component': false,
  '_outbox_progress_journal': 1,
  '_outbox_actor_id': 'fixture-auth',
  '_outbox_phase': 'prepared',
  '_outbox_store_id': 'store-1',
  '_outbox_session_id': 'session-1',
  '_outbox_station_type': 'floor',
  '_outbox_floor_label': '1F',
  '_outbox_order_item_id': 'line-1',
};

Map<String, dynamic> _receipt(String id) => {
  'event_id': id,
  'session_id': 'session-1',
  'order_item_id': 'line-1',
  'stage': 'floor_served',
  'delta': 1,
  'details': {'workflow_action': 'floor_served'},
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'an unauthenticated command does not persist or send an intent',
    () async {
      final store = _Store();
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((_) async {
          fail('an unauthenticated command must not send a request');
        }),
      );
      final notifier = _Notifier(client, store, authenticated: false);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      expect(
        await notifier.recordProgress(itemId: 'item-1', stage: 'floor_served'),
        EmergencyProgressResult.rejected,
      );
      expect(store.puts, 0);
      expect(notifier.state.error, 'EMERGENCY_USER_REQUIRED');
    },
  );

  test(
    'a replay round sends at most 20 commands and leaves deferred records queued',
    () async {
      final store = _Store();
      final ids = <String>{};
      for (var i = 0; i < 25; i++) {
        final id = const Uuid().v4();
        ids.add(id);
        await store.put(
          id,
          jsonEncode({
            ..._payload(id),
            '_outbox_phase': 'queued',
            'item_id': 'item-$i',
            'queue_id': 'queue-$i',
            '_outbox_order_item_id': 'line-$i',
          }),
        );
      }
      final sent = <String>[];
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/rpc/get_kds_progress_receipts_v1')) {
            return _json([]);
          }
          sent.add(jsonDecode(request.body)['p_event_id'] as String);
          return _json({'floor_served_quantity': 1});
        }),
      );
      final notifier = _Notifier(client, store);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      await notifier.flushOutboxForTesting();
      expect(sent, hasLength(20));
      expect(store.records, hasLength(5));
      expect(
        store.records.values.every(
          (r) => (jsonDecode(r.payload) as Map)['_outbox_phase'] == 'queued',
        ),
        isTrue,
      );
      await notifier.flushOutboxForTesting();
      expect(sent.toSet(), ids);
      expect(sent, hasLength(25));
      expect(store.records, isEmpty);
    },
  );

  test(
    'JeonGabok request UUID resolves its different event UUID after restart',
    () async {
      final store = _Store()..failBefore.add(2);
      Map<String, dynamic>? committed;
      var writes = 0;
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/rpc/get_kds_progress_receipts_v1')) {
            return _json([committed!]);
          }
          writes++;
          final id = jsonDecode(request.body)['p_event_id'] as String;
          committed = {
            ..._receipt(id),
            'actual_event_id': const Uuid().v4(),
            'stage': 'kitchen_done',
            'details': {
              'workflow_action': 'kitchen_done',
              'source_kind': 'base',
              'source_id': 'item-1',
            },
          };
          throw const SocketException('lost completion response');
        }),
      );
      addTearDown(client.dispose);
      final first = _Notifier(client, store)
        ..seed('store-1', station: 'kitchen');
      expect(
        await first.recordProgress(itemId: 'item-1', stage: 'kitchen_done'),
        EmergencyProgressResult.unknown,
      );
      first.dispose();
      final restarted = _Notifier(client, store)
        ..seed('store-1', station: 'kitchen');
      addTearDown(restarted.dispose);
      await restarted.flushOutboxForTesting();
      expect(writes, 1);
      expect(store.records, isEmpty);
    },
  );

  test(
    'unreadable storage produces unknown without sending or claiming a durable queue',
    () async {
      final store = _Store()
        ..failBefore.add(1)
        ..unreadable = true;
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((_) async {
          fail('a command must not be sent before durability is confirmed');
        }),
      );
      final notifier = _Notifier(client, store);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      expect(
        await notifier.recordProgress(itemId: 'item-1', stage: 'floor_served'),
        EmergencyProgressResult.unknown,
      );
      expect(notifier.state.pendingOutboxCount, 0);
      expect(notifier.state.pendingQueueIds, {'queue-1'});
    },
  );

  test('late successful handoff cannot replace the new store screen', () async {
    final store = _Store();
    final sent = Completer<void>(), response = Completer<http.Response>();
    final client = SupabaseClient(
      'http://fixture.invalid',
      'fixture',
      httpClient: MockClient((_) async {
        sent.complete();
        return response.future;
      }),
    );
    final notifier = _Notifier(client, store);
    addTearDown(notifier.dispose);
    addTearDown(client.dispose);
    final command = notifier.recordProgress(
      itemId: 'item-1',
      stage: 'floor_served',
    );
    await sent.future;
    notifier.seed('store-2');
    response.complete(_json({'floor_served_quantity': 1}));
    expect(await command, EmergencyProgressResult.confirmed);
    expect(notifier.state.restaurantId, 'store-2');
    expect(notifier.state.orders.single.items.single.floorServedQuantity, 0);
  });

  test(
    'failed local cleanup never changes a confirmed write into a queued command',
    () async {
      final store = _Store()..cannotDelete = true;
      var writes = 0;
      String? id;
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/rpc/get_kds_progress_receipts_v1')) {
            return _json([_receipt(id!)]);
          }
          writes++;
          id = jsonDecode(request.body)['p_event_id'] as String;
          return _json({'floor_served_quantity': 1});
        }),
      );
      final notifier = _Notifier(client, store);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      expect(
        await notifier.recordProgress(itemId: 'item-1', stage: 'floor_served'),
        EmergencyProgressResult.confirmed,
      );
      expect(store.records, hasLength(1));
      store.cannotDelete = false;
      await notifier.flushOutboxForTesting();
      expect(store.records, isEmpty);
      expect(writes, 1);
    },
  );

  test(
    'progress identity is durable before HTTP and removed after confirmation',
    () async {
      final store = _Store();
      var calls = 0;
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          calls++;
          expect(store.records, hasLength(1));
          final payload =
              jsonDecode(store.records.values.single.payload) as Map;
          expect(payload['_outbox_phase'], 'prepared');
          expect(
            jsonDecode(request.body)['p_event_id'],
            store.records.keys.single,
          );
          return _json({'floor_served_quantity': 1});
        }),
      );
      final notifier = _Notifier(client, store);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      expect(
        await notifier.recordProgress(itemId: 'item-1', stage: 'floor_served'),
        EmergencyProgressResult.confirmed,
      );
      expect(calls, 1);
      expect(store.records, isEmpty);
      expect(notifier.state.orders.single.items.single.floorServedQuantity, 1);
    },
  );

  test(
    'definite initial storage failure sends no request and never claims queued',
    () async {
      final store = _Store()..failBefore.add(1);
      var calls = 0;
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((_) async {
          calls++;
          return _json({});
        }),
      );
      final notifier = _Notifier(client, store);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      expect(
        await notifier.recordProgress(itemId: 'item-1', stage: 'floor_served'),
        EmergencyProgressResult.rejected,
      );
      expect(calls, 0);
      expect(notifier.state.error, 'KDS_PROGRESS_NOT_SAVED');
    },
  );

  test(
    'ambiguous local save remains unknown and manual recovery reuses its original event',
    () async {
      final store = _Store()..failAfter.add(1);
      final calls = <String>[];
      String? sentId;
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/rpc/get_kds_progress_receipts_v1')) {
            calls.add('read-result');
            return _json([]);
          }
          calls.add('write');
          sentId = jsonDecode(request.body)['p_event_id'] as String;
          return _json({'floor_served_quantity': 1});
        }),
      );
      final notifier = _Notifier(client, store);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      expect(
        await notifier.recordProgress(itemId: 'item-1', stage: 'floor_served'),
        EmergencyProgressResult.unknown,
      );
      final original = store.records.keys.single;
      expect(calls, isEmpty);
      expect(
        await notifier.flushOutboxForTesting(),
        'KDS_PROGRESS_RESULT_UNKNOWN',
      );
      expect(calls, [
        'read-result',
      ]); // no automatic write for a prepared record
      await notifier.reconcileUnknownProgress();
      expect(calls, ['read-result', 'read-result', 'write']);
      expect(sentId, original);
      expect(store.records, isEmpty);
      expect(notifier.state.pendingQueueIds, isEmpty);
    },
  );

  test(
    'lost commit response and failed queue update reconcile without a second write',
    () async {
      final store = _Store()..failBefore.add(2);
      var effects = 0;
      Map<String, dynamic>? committed;
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/rpc/get_kds_progress_receipts_v1')) {
            return _json([committed!]);
          }
          effects++;
          committed = _receipt(
            jsonDecode(request.body)['p_event_id'] as String,
          );
          throw const SocketException('lost response after commit');
        }),
      );
      final notifier = _Notifier(client, store);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      expect(
        await notifier.recordProgress(itemId: 'item-1', stage: 'floor_served'),
        EmergencyProgressResult.unknown,
      );
      expect(notifier.state.pendingQueueIds, {'queue-1'});
      expect(
        await notifier.recordProgress(itemId: 'item-1', stage: 'floor_served'),
        EmergencyProgressResult.rejected,
      );
      await notifier.flushOutboxForTesting();
      expect(effects, 1);
      expect(store.records, isEmpty);
    },
  );

  test(
    'gateway errors remain durable and do not become a rejected handoff',
    () async {
      final store = _Store();
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          if (request.url.path.endsWith('/rpc/get_kds_progress_receipts_v1')) {
            return _json([]);
          }
          return _json({
            'code': 'PGRST000',
            'message': 'gateway unavailable',
          }, status: 503);
        }),
      );
      final notifier = _Notifier(client, store);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      expect(
        await notifier.recordProgress(itemId: 'item-1', stage: 'floor_served'),
        EmergencyProgressResult.queued,
      );
      await notifier.flushOutboxForTesting();
      expect(store.records, hasLength(1));
      expect(
        (jsonDecode(store.records.values.single.payload)
            as Map)['_outbox_phase'],
        'queued',
      );
    },
  );

  test(
    '101 unconfirmed progress commands use two bounded result reads and zero writes',
    () async {
      final store = _Store();
      for (var i = 0; i < 101; i++) {
        final id = const Uuid().v4();
        await store.put(id, jsonEncode(_payload(id)));
      }
      final sizes = <int>[];
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          expect(
            request.url.path,
            endsWith('/rpc/get_kds_progress_receipts_v1'),
          );
          final body = jsonDecode(request.body) as Map;
          expect(body['p_store_id'], 'store-1');
          sizes.add((body['p_operation_ids'] as List).length);
          return _json([]);
        }),
      );
      final notifier = _Notifier(client, store);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      expect(
        await notifier.flushOutboxForTesting(),
        'KDS_PROGRESS_RESULT_UNKNOWN',
      );
      expect(sizes, [100, 1]);
      expect(store.records, hasLength(101));
    },
  );

  test(
    'an actor or station change cannot replay or remove another assignment journal',
    () async {
      final store = _Store();
      final id = const Uuid().v4();
      expect(
        kdsOutboxScopeMatches(
          _payload(id),
          storeId: 'store-1',
          actorId: 'fixture-auth',
          sessionId: 'session-1',
          stationType: 'floor',
          floorLabel: '1F',
        ),
        isTrue,
      );
      await store.put(
        id,
        jsonEncode({..._payload(id), '_outbox_actor_id': 'other-actor'}),
      );
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((_) async {
          fail('different actor must not issue a request');
        }),
      );
      final notifier = _Notifier(client, store);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      await notifier.flushOutboxForTesting();
      expect(store.records, hasLength(1));
      for (final changed in [
        {'_outbox_store_id': 'other-store'},
        {'_outbox_session_id': 'other-session'},
        {'_outbox_station_type': 'tray'},
        {'_outbox_floor_label': '2F'},
      ]) {
        expect(
          kdsOutboxScopeMatches(
            {..._payload(id), ...changed},
            storeId: 'store-1',
            actorId: 'fixture-auth',
            sessionId: 'session-1',
            stationType: 'floor',
            floorLabel: '1F',
          ),
          isFalse,
        );
      }
    },
  );

  test(
    'result lookup validates quantity, target and session as well as event UUID',
    () {
      const id = '00000000-0000-4000-8000-000000000001';
      expect(kdsProgressReceiptMatches(_payload(id), _receipt(id)), isTrue);
      for (final changed in [
        {'event_id': 'other'},
        {'delta': -1},
        {'order_item_id': 'other-line'},
        {'session_id': 'other-session'},
        {
          'details': {'workflow_action': 'kitchen_done'},
        },
      ]) {
        expect(
          kdsProgressReceiptMatches(_payload(id), {
            ..._receipt(id),
            ...changed,
          }),
          isFalse,
        );
      }
    },
  );
}
