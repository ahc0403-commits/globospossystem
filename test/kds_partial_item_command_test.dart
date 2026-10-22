import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/emergency_web_bridge.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Notifier extends EmergencyFulfillmentNotifier {
  void seed(EmergencyFulfillmentState value) => state = value;

  _Notifier(SupabaseClient client) : super(client: client) {
    state = EmergencyFulfillmentState.fromJson({
      'assigned': true,
      'active': true,
      'restaurant_id': 'store-1',
      'session_id': 'session-1',
      'station_type': 'floor',
      'orders': [_ticket],
    });
  }
}

final _ticket = <String, dynamic>{
  'queue_id': 'queue-1',
  'order_id': 'order-1',
  'queue_no': 1,
  'table_number': '101',
  'floor_label': '1F',
  'workflow_version': 2,
  'created_at': '2026-10-22T01:00:00Z',
  'items': [
    {
      'id': 'item-1',
      'order_item_id': 'line-1',
      'name_ko': '음식',
      'name_vi': 'Meal',
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
};

Map<String, dynamic> _progress({int served = 1}) => {
  'kitchen_started_quantity': 2,
  'kitchen_done_quantity': 1,
  'tray_received_quantity': 1,
  'tray_dispatched_quantity': 1,
  'floor_served_quantity': served,
};

http.Response _json(Object value, {int status = 200}) => http.Response(
  jsonEncode(value),
  status,
  request: http.Request(
    'POST',
    Uri.parse('http://fixture.invalid/rest/v1/rpc/fixture'),
  ),
  headers: {'content-type': 'application/json'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'floor-direct drinks retain the one-item RPC and excused quantity limit',
    () async {
      final calls = <http.Request>[];
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          calls.add(request);
          return _json({'floor_served_quantity': 1});
        }),
      );
      final notifier = _Notifier(client);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      notifier.seed(
        notifier.state.copyWith(
          orders: [
            notifier.state.orders.single.copyWith(
              items: [
                EmergencyFulfillmentItem.fromJson({
                  'id': 'drink-1',
                  'order_item_id': 'drink-line',
                  'ordered_quantity': 2,
                  'excused_quantity': 1,
                  'floor_served_quantity': 0,
                  'fulfillment_route': 'floor_direct',
                }),
              ],
            ),
          ],
        ),
      );
      expect(
        await notifier.recordProgress(itemId: 'drink-1', stage: 'floor_served'),
        EmergencyProgressResult.confirmed,
      );
      expect(
        calls.single.url.path,
        endsWith('/rpc/emergency_record_floor_direct_progress'),
      );
      expect(notifier.state.orders.single.items.single.requiredQuantity, 1);
      expect(notifier.state.orders.single.items.single.floorServedQuantity, 1);
    },
  );

  test('confirmed undo updates a menu opened from completed history', () async {
    final client = SupabaseClient(
      'http://fixture.invalid',
      'fixture',
      httpClient: MockClient(
        (_) async => _json({
          ..._progress(),
          'kitchen_done_quantity': 2,
          'tray_received_quantity': 2,
          'tray_dispatched_quantity': 2,
        }),
      ),
    );
    final notifier = _Notifier(client);
    addTearDown(notifier.dispose);
    addTearDown(client.dispose);
    final completed = notifier.state.orders.single.copyWith(
      items: [
        notifier.state.orders.single.items.single
            .withStage('kitchen_done', 2)
            .withStage('tray_dispatched', 2)
            .withStage('floor_served', 2),
      ],
    );
    notifier.seed(
      notifier.state.copyWith(orders: [], completedOrders: [completed]),
    );
    expect(
      await notifier.recordProgress(
        itemId: 'item-1',
        stage: 'floor_served',
        delta: -1,
      ),
      EmergencyProgressResult.confirmed,
    );
    expect(notifier.state.orders.single.items.single.floorServedQuantity, 1);
    expect(notifier.state.completedOrders, isEmpty);
  });

  test(
    'single partial serve waits for confirmation and makes one RPC',
    () async {
      final calls = <http.Request>[];
      final gate = Completer<http.Response>();
      final sent = Completer<void>();
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) {
          calls.add(request);
          sent.complete();
          return gate.future;
        }),
      );
      final notifier = _Notifier(client);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);

      final pending = notifier.recordProgress(
        itemId: 'item-1',
        stage: 'floor_served',
      );
      await sent.future;
      expect(notifier.state.orders.single.items.single.floorServedQuantity, 0);
      expect(
        await notifier.recordProgress(itemId: 'item-1', stage: 'floor_served'),
        EmergencyProgressResult.rejected,
      );
      gate.complete(_json(_progress()));
      expect(await pending, EmergencyProgressResult.confirmed);
      final item = notifier.state.orders.single.items.single;
      expect(item.floorServedQuantity, 1);
      expect(item.kitchenStartedQuantity, 2);
      expect(item.kitchenDoneQuantity, 1);
      expect(
        calls.single.url.path,
        endsWith('/rpc/kds_record_station_progress_v3'),
      );
      expect(jsonDecode(calls.single.body)['p_action'], 'floor_served');
      expect(notifier.state.orders.single.isCompleteAt('floor'), isFalse);
      expect(await EmergencyWebBridge.readOutbox(), isEmpty);
    },
  );

  test(
    'server rejection preserves realtime state instead of restoring a snapshot',
    () async {
      final gate = Completer<http.Response>();
      final sent = Completer<void>();
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((_) {
          sent.complete();
          return gate.future;
        }),
      );
      final notifier = _Notifier(client);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      final pending = notifier.recordProgress(
        itemId: 'item-1',
        stage: 'floor_served',
      );
      await sent.future;
      notifier.applyRealtimeItemRowForTesting({'id': 'item-1', ..._progress()});
      gate.complete(
        _json({
          'code': 'P0001',
          'message': 'EMERGENCY_QUANTITY_CHAIN_VIOLATION',
        }, status: 400),
      );
      expect(await pending, EmergencyProgressResult.rejected);
      expect(notifier.state.orders.single.items.single.floorServedQuantity, 1);
      expect(notifier.state.error, 'EMERGENCY_QUANTITY_CHAIN_VIOLATION');
      expect(await EmergencyWebBridge.readOutbox(), isEmpty);
    },
  );

  test(
    'transport failure queues one durable request without completing the item',
    () async {
      var writes = 0;
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((_) async {
          writes++;
          throw const SocketException('offline');
        }),
      );
      final notifier = _Notifier(client);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      expect(
        await notifier.recordProgress(itemId: 'item-1', stage: 'floor_served'),
        EmergencyProgressResult.queued,
      );
      expect(notifier.state.orders.single.items.single.floorServedQuantity, 0);
      expect(notifier.state.pendingQueueIds, {'queue-1'});
      final records = await EmergencyWebBridge.readOutbox();
      expect(records, hasLength(1));
      final payload = jsonDecode(records.single.payload);
      expect(payload['event_id'], records.single.id);
      expect(payload['_outbox_store_id'], 'store-1');
      expect(payload['queue_id'], 'queue-1');
      expect(
        await notifier.recordProgress(itemId: 'item-1', stage: 'floor_served'),
        EmergencyProgressResult.rejected,
      );
      expect(writes, 1);
    },
  );

  test(
    'bulk uses one write plus one ticket read and keeps unprepared quantities',
    () async {
      final calls = <String>[];
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          final rpc = request.url.path.split('/').last;
          calls.add(rpc);
          if (rpc == 'kds_serve_ready_order_v3') {
            return _json({'changed_quantity': 1});
          }
          expect(rpc, 'get_kds_ticket_v2');
          final item =
              (_ticket['items'] as List).single as Map<String, dynamic>;
          return _json({
            'revision': 1,
            'ticket': {
              ..._ticket,
              'items': [
                {...item, ..._progress()},
              ],
            },
          });
        }),
      );
      final notifier = _Notifier(client);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      expect(await notifier.completeOrder(queueId: 'queue-1'), isTrue);
      expect(calls, ['kds_serve_ready_order_v3', 'get_kds_ticket_v2']);
      final item = notifier.state.orders.single.items.single;
      expect(item.floorServedQuantity, 1);
      expect(item.kitchenDoneQuantity, 1);
      expect(item.requiredQuantity, 2);
      expect(await EmergencyWebBridge.readOutbox(), isEmpty);
    },
  );

  test(
    'committed bulk is not queued again when its confirmation read fails',
    () async {
      final calls = <String>[];
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          final rpc = request.url.path.split('/').last;
          calls.add(rpc);
          if (rpc == 'kds_serve_ready_order_v3') {
            return _json({'changed_quantity': 1});
          }
          throw const SocketException('read failed after commit');
        }),
      );
      final notifier = _Notifier(client);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      expect(await notifier.completeOrder(queueId: 'queue-1'), isTrue);
      expect(calls, ['kds_serve_ready_order_v3', 'get_kds_ticket_v2']);
      expect(notifier.state.error, 'EMERGENCY_ORDER_REFRESH_PENDING');
      expect(await EmergencyWebBridge.readOutbox(), isEmpty);
    },
  );

  test(
    'newer realtime state triggers one scoped read instead of overwriting it',
    () async {
      final gate = Completer<http.Response>();
      final sent = Completer<void>();
      final calls = <String>[];
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) {
          final rpc = request.url.path.split('/').last;
          calls.add(rpc);
          if (rpc == 'kds_record_station_progress_v3') {
            sent.complete();
            return gate.future;
          }
          return Future.value(
            _json({
              'revision': 2,
              'ticket': {
                ..._ticket,
                'items': [
                  {
                    ...(_ticket['items'] as List).single as Map,
                    ..._progress(),
                    'kitchen_done_quantity': 2,
                    'tray_received_quantity': 2,
                    'tray_dispatched_quantity': 2,
                  },
                ],
              },
            }),
          );
        }),
      );
      final notifier = _Notifier(client);
      addTearDown(notifier.dispose);
      addTearDown(client.dispose);
      final pending = notifier.recordProgress(
        itemId: 'item-1',
        stage: 'floor_served',
      );
      await sent.future;
      notifier.applyRealtimeItemRowForTesting({
        'id': 'item-1',
        ..._progress(),
        'kitchen_done_quantity': 2,
        'tray_received_quantity': 2,
        'tray_dispatched_quantity': 2,
      });
      gate.complete(_json(_progress()));
      expect(await pending, EmergencyProgressResult.confirmed);
      expect(notifier.state.orders.single.items.single.kitchenDoneQuantity, 2);
      expect(calls, ['kds_record_station_progress_v3', 'get_kds_ticket_v2']);
    },
  );
}
