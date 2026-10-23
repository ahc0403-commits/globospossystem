import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> ticket(int n) => {
  'queue_id': 'queue-$n',
  'order_id': 'order-$n',
  'queue_no': n,
  'table_number': '$n',
  'floor_label': '1F',
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
  String floor = '1F';
  int active = 0;
  int maxActive = 0;
  final calls = <String>[];
  final historyBodies = <Map<String, dynamic>>[];
  Future<http.Response> Function(Map<String, dynamic>)? history;
  Future<http.Response> Function()? timing;
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
              'mode': 'legacy',
              'assigned': true,
              'restaurant_id': bunsikKdsStoreId,
            });
          case 'get_emergency_station_snapshot':
            return response({
              'assigned': true,
              'active': true,
              'restaurant_id': bunsikKdsStoreId,
              'session_id': 'session-1',
              'station_type': 'floor',
              'floor_label': floor,
              'orders': [ticket(snapshotNumber)],
            });
          case 'get_bunsik_kds_completed_page_v1':
            final body = Map<String, dynamic>.from(
              jsonDecode(request.body) as Map,
            );
            historyBodies.add(body);
            return history == null
                ? response({
                    'orders': [ticket(1)],
                    'has_more': false,
                  })
                : await history!(body);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'a stale history page cannot repeat kitchen, handoff or drink alarms',
    () {
      EmergencyFulfillmentOrder order(int quantity, {bool drink = false}) =>
          EmergencyFulfillmentOrder.fromJson({
            ...ticket(1),
            'items': [
              {
                'id': 'item-1',
                'order_item_id': 'line-1',
                'ordered_quantity': quantity,
                'kitchen_started_quantity': quantity,
                'kitchen_done_quantity': quantity,
                'tray_received_quantity': quantity,
                'tray_dispatched_quantity': quantity,
                'floor_served_quantity': 1,
                'fulfillment_route': drink
                    ? 'floor_direct'
                    : 'kitchen_tray_floor',
              },
            ],
          });
      for (final station in ['kitchen', 'floor']) {
        final state = EmergencyFulfillmentState(
          restaurantId: bunsikKdsStoreId,
          sessionId: 'session-1',
          stationType: station,
          orders: [order(2)],
          completedOrders: [order(1)],
        );
        expect(
          emergencyKitchenAdditionalOrderNotices(state, state.copyWith()),
          isEmpty,
        );
        expect(emergencyHandoffNotices(state, state.copyWith()), isEmpty);
      }
      final drinks = EmergencyFulfillmentState(
        restaurantId: bunsikKdsStoreId,
        sessionId: 'session-1',
        stationType: 'floor',
        orders: [order(2, drink: true)],
        completedOrders: [order(1, drink: true)],
      );
      expect(
        emergencyFloorDirectBeverageNotices(drinks, drinks.copyWith()),
        isEmpty,
      );
    },
  );

  test(
    'slow failed history does not block handoff snapshots; reads stay at two',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final gate = Completer<http.Response>();
      f.history = (_) => gate.future;
      await f.start();
      final pendingHistory = f.notifier.loadCompletedHistory();
      await f.settle();
      expect(f.notifier.state.completedHistory.loading, isTrue);
      f.snapshotNumber = 2;
      await f.notifier.load(showLoading: false);
      expect(f.notifier.state.orders.single.queueId, 'queue-2');
      expect(f.notifier.state.completedHistory.loading, isTrue);
      expect(f.maxActive, lessThanOrEqualTo(2));
      gate.complete(response({'message': 'timeout'}, status: 500));
      await pendingHistory;
      await f.settle();
      expect(f.notifier.state.completedHistory.error, 'KDS_HISTORY_FAILED');
      expect(f.notifier.state.orders.single.queueId, 'queue-2');
      expect(f.calls, isNot(contains('get_emergency_station_today_completed')));
    },
  );

  test(
    'history is demand loaded, duplicate requests share work, page memory is bounded',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      await f.start();
      expect(f.historyBodies, isEmpty);
      final gate = Completer<http.Response>();
      f.history = (_) => gate.future;
      final request = f.notifier.loadCompletedHistory();
      await Future.wait(
        List.generate(40, (_) => f.notifier.loadCompletedHistory()),
      );
      await f.settle();
      expect(f.historyBodies, hasLength(1));
      gate.complete(
        response({
          'orders': List.generate(50, ticket),
          'has_more': true,
          'next_cursor': {
            'completed_at': '2026-10-23T01:00:00Z',
            'queue_id': 'queue-49',
          },
        }),
      );
      await request;
      expect(f.notifier.state.completedOrders, hasLength(50));
      f.history = (body) async => response({
        'orders': [ticket(51)],
        'has_more': false,
        'next_cursor': {
          'completed_at': '2026-10-23T00:00:00Z',
          'queue_id': 'queue-51',
        },
      });
      await f.notifier.loadCompletedHistory(direction: 1);
      expect(f.historyBodies.last['p_limit'], 50);
      expect(f.historyBodies.last['p_before_queue_id'], 'queue-49');
      expect(f.notifier.state.completedOrders.single.queueId, 'queue-51');
      expect(f.notifier.state.completedHistory.page, 1);
      await f.notifier.loadCompletedHistory(direction: -1);
      expect(f.historyBodies.last['p_before_queue_id'], isNull);
      expect(f.notifier.state.completedHistory.page, 0);
      expect(f.maxActive, lessThanOrEqualTo(2));
    },
  );

  test('old floor response is discarded after reassignment', () async {
    final f = Fixture();
    addTearDown(f.close);
    await f.start();
    final gate = Completer<http.Response>();
    f.history = (_) => gate.future;
    final request = f.notifier.loadCompletedHistory();
    await f.settle();
    f.floor = '2F';
    await f.notifier.load(showLoading: false);
    gate.complete(
      response({
        'orders': [ticket(9)],
        'has_more': false,
      }),
    );
    await request;
    expect(f.notifier.state.floorLabel, '2F');
    expect(f.notifier.state.completedOrders, isEmpty);
    expect(f.notifier.state.completedHistory.loading, isFalse);
  });

  test(
    'oversized and failed pages retain previous history and cursor',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      await f.start();
      await f.notifier.loadCompletedHistory();
      f.history = (_) async =>
          response({'orders': List.generate(51, ticket), 'has_more': false});
      await f.notifier.loadCompletedHistory();
      expect(f.notifier.state.completedOrders.single.queueId, 'queue-1');
      expect(f.notifier.state.completedHistory.error, 'KDS_HISTORY_FAILED');
    },
  );

  test(
    'authoritative null timing clears a preserved completion timer',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      f.timing = () async => response([
        {'queue_id': 'queue-1', 'station_completed_at': '2026-10-23T01:05:00Z'},
      ]);
      await f.start();
      expect(f.notifier.state.orders.single.stationCompletedAt, isNotNull);
      f.timing = () async => response([
        {'queue_id': 'queue-1', 'station_completed_at': null},
      ]);
      await f.notifier.load(showLoading: false);
      await f.settle();
      expect(f.notifier.state.orders.single.stationCompletedAt, isNull);
    },
  );

  test('stale auxiliary replies trigger one fresh trailing read', () async {
    final f = Fixture();
    addTearDown(f.close);
    final stale = Completer<http.Response>();
    final fresh = Completer<http.Response>();
    var calls = 0;
    f.timing = () => ++calls == 1 ? stale.future : fresh.future;
    await f.start();
    f.snapshotNumber = 3;
    await f.notifier.load(showLoading: false);
    stale.complete(
      response([
        {'queue_id': 'queue-3', 'station_completed_at': '2026-10-23T01:05:00Z'},
      ]),
    );
    await f.settle();
    expect(calls, 2);
    expect(f.notifier.state.orders.single.stationCompletedAt, isNull);
    fresh.complete(
      response([
        {
          'queue_id': 'queue-3',
          'station_started_at': '2026-10-23T01:06:00Z',
          'station_completed_at': null,
        },
      ]),
    );
    await f.settle();
    expect(
      f.notifier.state.orders.single.stationStartedAt,
      DateTime.parse('2026-10-23T01:06:00Z'),
    );
    expect(calls, 2);
    expect(f.maxActive, lessThanOrEqualTo(2));
  });

  test(
    'stalled auxiliary timing does not hold the foreground refresh lock',
    () async {
      final f = Fixture();
      addTearDown(f.close);
      final gate = Completer<http.Response>();
      f.timing = () => gate.future;
      await f.start();
      f.snapshotNumber = 3;
      await Future.wait(
        List.generate(40, (_) => f.notifier.load(showLoading: false)),
      );
      await f.settle();
      expect(f.notifier.state.orders.single.queueId, 'queue-3');
      expect(
        f.calls.where((c) => c == 'get_emergency_station_timings'),
        hasLength(1),
      );
      expect(f.maxActive, lessThanOrEqualTo(2));
      gate.complete(response([]));
      await f.settle();
    },
  );
}
