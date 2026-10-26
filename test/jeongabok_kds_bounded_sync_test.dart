import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/kds_realtime_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> ticket(int n) => {
  'queue_id': 'queue-$n',
  'order_id': 'order-$n',
  'queue_no': n,
  'table_number': '$n',
  'floor_label': '2F',
  'created_at': '2026-10-23T01:00:00Z',
  'items': [
    {
      'id': 'item-$n',
      'order_item_id': 'line-$n',
      'ordered_quantity': 1,
      'kitchen_done_quantity': 1,
      'tray_received_quantity': 1,
      'tray_dispatched_quantity': 1,
      'floor_served_quantity': 0,
    },
  ],
};
http.Response response(Object? value, {int status = 200}) => http.Response(
  jsonEncode(value),
  status,
  request: http.Request(
    'POST',
    Uri.parse('http://fixture.invalid/rest/v1/rpc/fixture'),
  ),
  headers: {'content-type': 'application/json'},
);

class Fixture {
  int snapshotNumber = 1;
  String floor = '2F';
  String? ticketFloor;
  Completer<void>? ticketGate;
  int active = 0;
  int maxActive = 0;
  final calls = <String>[];
  final historyBodies = <Map<String, dynamic>>[];
  Future<http.Response> Function(Map<String, dynamic>)? history;
  Future<http.Response> Function()? timing;
  final batches = <List<String>>[];
  int batchRevision = 500;
  int failBatch = 0;
  bool omitTombstone = false;

  late final client = SupabaseClient(
    'http://fixture.invalid',
    'fixture',
    httpClient: MockClient((request) async {
      final rpc = request.url.path.split('/').last;
      calls.add(rpc);
      active++;
      if (active > maxActive) maxActive = active;
      try {
        await Future<void>.delayed(Duration.zero);
        switch (rpc) {
          case 'get_kds_sync_config':
            return response({
              'mode': 'active',
              'bounded_sync_version': 3,
              'revision': 5,
              'session_id': 'session-1',
              'station_type': 'floor',
              'floor_label': floor,
              'service_area_codes': [floor],
              'assigned': true,
              'restaurant_id': '273b057e-3b69-46e3-93c1-6194c2802849',
            });
          case 'get_jeongabok_kds_bootstrap_v3':
            return response({
              'sync': {
                'mode': 'active',
                'bounded_sync_version': 3,
                'revision': 5,
                'assigned': true,
                'restaurant_id': '273b057e-3b69-46e3-93c1-6194c2802849',
                'session_id': 'session-1',
                'station_type': 'floor',
                'floor_label': floor,
                'service_area_codes': [floor],
              },
              'snapshot': {
                'assigned': true,
                'active': true,
                'restaurant_id': '273b057e-3b69-46e3-93c1-6194c2802849',
                'session_id': 'session-1',
                'station_type': 'floor',
                'floor_label': floor,
                'orders': [ticket(snapshotNumber)],
              },
              'completed_orders': [],
              'timings': [],
              'fulfillment_mode': 'paperless',
            });
          case 'get_jeongabok_kds_completed_page_v1':
            final body = Map<String, dynamic>.from(
              jsonDecode(request.body) as Map,
            );
            historyBodies.add(body);
            return history == null
                ? response({
                    'orders': [ticket(1)],
                    'has_more': false,
                    'sync': {
                      'mode': 'active',
                      'assigned': true,
                      'bounded_sync_version': 3,
                      'restaurant_id': '273b057e-3b69-46e3-93c1-6194c2802849',
                      'session_id': 'session-1',
                      'station_type': 'floor',
                      'floor_label': floor,
                      'service_area_codes': [floor],
                    },
                  })
                : await history!(body);
          case 'get_jeongabok_kds_tickets_v3':
            if (ticketGate != null) await ticketGate!.future;
            final ids = List<String>.from(
              (jsonDecode(request.body) as Map)['p_queue_ids'],
            );
            batches.add(ids);
            if (failBatch == batches.length) {
              return response({
                'code': '22023',
                'message': 'fixture rejected',
              }, status: 400);
            }
            return response({
              'revision': batchRevision,
              'sync': {
                'mode': 'active',
                'assigned': true,
                'bounded_sync_version': 3,
                'restaurant_id': '273b057e-3b69-46e3-93c1-6194c2802849',
                'session_id': 'session-1',
                'station_type': 'floor',
                'floor_label': ticketFloor ?? floor,
                'service_area_codes': [ticketFloor ?? floor],
              },
              'tickets': [
                for (final id in ids.where(
                  (id) => !omitTombstone || id != ids.last,
                ))
                  {
                    'queue_id': id,
                    'ticket': id == 'missing'
                        ? null
                        : ticket(int.parse(id.split('-').last)),
                  },
              ],
            });
          case 'get_emergency_station_timings':
            return timing == null ? response([]) : await timing!();
          case 'get_store_fulfillment_mode':
            return response('paperless');
          default:
            throw StateError('Unexpected RPC: $rpc');
        }
      } finally {
        active--;
      }
    }),
  );
  late final notifier = EmergencyFulfillmentNotifier(
    client: client,
    enableRealtimeSubscriptions: false,
  );

  Future<void> settle() async {
    await pumpEventQueue(times: 20);
  }

  Future<void> start() async {
    await notifier.load();
    await settle();
    expect(
      notifier.state.error,
      isNull,
      reason: 'Initial snapshot failed; calls=$calls',
    );
  }

  Future<void> close() async {
    notifier.dispose();
    await client.dispose();
  }
}

KdsChangeEnvelope change(
  int revision,
  String id, {
  String kind = 'ticket_invalidated',
}) => KdsChangeEnvelope(
  schemaVersion: 1,
  restaurantId: '273b057e-3b69-46e3-93c1-6194c2802849',
  sessionId: 'session-1',
  revision: revision,
  eventId: 'e-$revision',
  eventType: 'ticket_changed',
  targetStations: const ['floor'],
  queueId: id,
  payload: {'kind': kind},
  occurredAt: DateTime.utc(2026, 10, 23),
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });
  test(
    'bootstrap publishes without mandatory history; history shares one lane',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      await f.start();
      expect(f.notifier.state.boundedJeongabok, true);
      expect(f.calls, [
        'get_kds_sync_config',
        'get_jeongabok_kds_bootstrap_v3',
      ]);
      final pending = Completer<http.Response>();
      f.history = (_) => pending.future;
      final history = f.notifier.loadCompletedHistory();
      await f.settle();
      final foreground = f.notifier.load(showLoading: false);
      await f.settle();
      expect(f.calls.last, 'get_jeongabok_kds_completed_page_v1');
      expect(f.maxActive, 1);
      pending.complete(
        response({
          'orders': [],
          'has_more': false,
          'sync': {
            'mode': 'active',
            'assigned': true,
            'bounded_sync_version': 3,
            'restaurant_id': '273b057e-3b69-46e3-93c1-6194c2802849',
            'session_id': 'session-1',
            'station_type': 'floor',
            'floor_label': f.floor,
            'service_area_codes': [f.floor],
          },
        }),
      );
      await Future.wait([history, foreground]);
      expect(f.maxActive, 1);
    },
  );
  test(
    '100 unique IDs and duplicates use two sequential bounded batches',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      await f.start();
      final events = [
        for (var i = 1; i <= 100; i++) change(i, 'queue-$i'),
        for (var i = 1; i <= 20; i++) change(100 + i, 'queue-$i'),
      ];
      await f.notifier.applyKdsBatchForTesting(events);
      expect(f.batches.map((b) => b.length), [50, 50]);
      expect(f.maxActive, 1);
      expect(f.notifier.state.orders.length, 100);
      expect(f.calls.where((c) => c == 'get_kds_ticket_v2'), isEmpty);
    },
  );
  test('control event is a deduplication barrier', () async {
    final f = Fixture();
    addTearDown(f.close);
    await f.start();
    await f.notifier.applyKdsBatchForTesting([
      change(1, 'queue-1'),
      change(2, 'queue-1'),
      change(3, 'queue-1', kind: 'leftover_changed'),
      change(4, 'queue-1'),
    ]);
    expect(f.batches, [
      ['queue-1'],
      ['queue-1'],
    ]);
  });
  test(
    'partial batch failure is surfaced without per-ticket fallback',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      await f.start();
      f.failBatch = 2;
      await expectLater(
        f.notifier.applyKdsBatchForTesting([
          for (var i = 1; i <= 100; i++) change(i, 'queue-$i'),
        ]),
        throwsA(isA<PostgrestException>()),
      );
      expect(f.batches.length, 2);
      expect(f.notifier.state.orders.length, 50);
      expect(f.maxActive, 1);
    },
  );
  test('incomplete tombstones and stale revisions fail closed', () async {
    final f = Fixture();
    addTearDown(f.close);
    await f.start();
    f.omitTombstone = true;
    await expectLater(
      f.notifier.applyKdsBatchForTesting([change(1, 'queue-1')]),
      throwsFormatException,
    );
    f.omitTombstone = false;
    f.batchRevision = 0;
    await expectLater(
      f.notifier.applyKdsBatchForTesting([change(1, 'queue-1')]),
      throwsStateError,
    );
    expect(f.notifier.state.orders.length, 1);
  });
  test(
    'a server assignment change cannot apply another floors tickets',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      await f.start();
      f.ticketFloor = '3F';
      await expectLater(
        f.notifier.applyKdsBatchForTesting([change(1, 'queue-2')]),
        throwsStateError,
      );
      await f.settle();
      expect(f.notifier.state.orders.map((o) => o.queueId), ['queue-1']);
    },
  );
  test('a slow ticket cannot overwrite confirmed progress', () async {
    final f = Fixture();
    addTearDown(f.close);
    await f.start();
    f.ticketGate = Completer<void>();
    final pending = f.notifier.applyKdsBatchForTesting([change(1, 'queue-1')]);
    await f.settle();
    expect(
      f.notifier.applyRealtimeItemRowForTesting({
        'id': 'item-1',
        'ordered_quantity': 1,
        'kitchen_done_quantity': 1,
        'tray_received_quantity': 1,
        'tray_dispatched_quantity': 1,
        'floor_served_quantity': 1,
      }),
      true,
    );
    final assertion = expectLater(pending, throwsStateError);
    f.ticketGate!.complete();
    await assertion;
    expect(f.notifier.state.orders.single.items.single.floorServedQuantity, 1);
  });
  test(
    'slow history cannot replace newer progress or leave loading stuck',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      await f.start();
      final gate = Completer<http.Response>();
      f.history = (_) => gate.future;
      final pending = f.notifier.loadCompletedHistory();
      await f.settle();
      expect(
        f.notifier.applyRealtimeItemRowForTesting({
          'id': 'item-1',
          'ordered_quantity': 1,
          'kitchen_done_quantity': 1,
          'tray_received_quantity': 1,
          'tray_dispatched_quantity': 1,
          'floor_served_quantity': 1,
        }),
        true,
      );
      gate.complete(
        response({
          'orders': [ticket(1)],
          'has_more': false,
        }),
      );
      await pending;
      expect(
        f.notifier.state.orders.single.items.single.floorServedQuantity,
        1,
      );
      expect(f.notifier.state.completedOrders, isEmpty);
      expect(f.notifier.state.completedHistory.loading, false);
    },
  );
  test('transient reads stop at three attempts and retain one lane', () async {
    final lane = KdsReadCoordinator();
    var attempts = 0;
    var active = 0;
    var maximum = 0;
    final first = lane.run(() async {
      active++;
      maximum = active > maximum ? active : maximum;
      attempts++;
      active--;
      throw const PostgrestException(message: 'pool', code: 'PGRST003');
    });
    final next = lane.run(() async {
      active++;
      maximum = active > maximum ? active : maximum;
      active--;
      return 'next';
    });
    await expectLater(first, throwsA(isA<PostgrestException>()));
    expect(await next, 'next');
    expect(attempts, 3);
    expect(maximum, 1);
  });
  test(
    'permanent failures release coordinator without retry amplification',
    () async {
      final lane = KdsReadCoordinator();
      var reads = 0;
      await expectLater(
        lane.run(() async {
          reads++;
          throw const PostgrestException(message: 'scope', code: '42501');
        }),
        throwsA(isA<PostgrestException>()),
      );
      expect(await lane.run(() async => ++reads), 2);
    },
  );
}
