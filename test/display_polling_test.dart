import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/customer_display/customer_display_provider.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/kds_realtime_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/display_sync_server.dart';

void main() {
  late DisplaySyncServer server;
  late CustomerDisplayNotifier display;
  late EmergencyFulfillmentNotifier kds;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    server = DisplaySyncServer();
    await server.start();
    display = CustomerDisplayNotifier(client: server.client);
    kds = EmergencyFulfillmentNotifier(client: server.client);
  });
  tearDown(() async {
    if (display.mounted) display.dispose();
    if (kds.mounted) kds.dispose();
    await server.close();
  });

  Future<void> startBoth() async {
    await Future.wait([display.start('store-1'), kds.load()]);
    await waitUntil(() => server.subscriptions.length == 2);
    await Future<void>.delayed(const Duration(milliseconds: 400));
  }

  test(
    'healthy displays use two safety reads per ten seconds, not ten',
    () async {
      await startBoth();
      final displayBefore = server.count('customer_payment_displays');
      final kdsBefore = server.count('get_emergency_station_snapshot');
      // Simulate silently dropped events while the socket still says subscribed.
      server.displayRows['store-1'] = DisplaySyncServer.displayRow(
        'silent-update',
      );
      server.snapshot = {...server.snapshot, 'active': false};
      await Future<void>.delayed(const Duration(milliseconds: 10100));
      expect(server.count('customer_payment_displays') - displayBefore, 2);
      expect(server.count('get_emergency_station_snapshot') - kdsBefore, 2);
      expect(display.state.snapshot?.orderId, 'silent-update');
      expect(kds.state.active, isFalse);
    },
  );

  test(
    'customer display coalesces concurrent retries behind a slow read',
    () async {
      final held = Completer<void>();
      server.beforeReply = (path) async {
        if (path == 'customer_payment_displays') await held.future;
      };
      final initial = display.start('store-1');
      await waitUntil(() => server.count('customer_payment_displays') == 1);
      final retries = [for (var i = 0; i < 20; i++) display.retry()];
      await Future<void>.delayed(const Duration(milliseconds: 200));
      final readsWhileHeld = server.count('customer_payment_displays');
      held.complete();
      await initial;
      await Future.wait(retries);
      expect(readsWhileHeld, 1);
      expect(server.count('customer_payment_displays'), 2);
    },
  );

  test('KDS coalesces a realtime burst into one complete refresh', () async {
    await startBoth();
    final before = server.count('get_emergency_station_snapshot');
    server.snapshot = {...server.snapshot, 'active': false};
    for (var i = 0; i < 20; i++) {
      server.change('emergency_order_queue', {'id': 'queue-1'});
    }
    await waitUntil(() => !kds.state.active);
    await Future<void>.delayed(const Duration(milliseconds: 250));
    expect(server.count('get_emergency_station_snapshot') - before, 1);
  });

  test(
    'display and KDS item events apply immediately without a read',
    () async {
      await startBoth();
      final displayBefore = server.count('customer_payment_displays');
      final kdsBefore = server.count('get_emergency_station_snapshot');
      server.change(
        'customer_payment_displays',
        DisplaySyncServer.displayRow('live-update'),
      );
      server.change('emergency_fulfillment_items', {
        'id': 'item-1',
        'kitchen_done_quantity': 2,
        'tray_received_quantity': 0,
        'tray_dispatched_quantity': 0,
        'floor_served_quantity': 0,
      });
      await waitUntil(
        () =>
            display.state.snapshot?.orderId == 'live-update' &&
            kds.state.orders.single.items.single.kitchenDoneQuantity == 2,
      );
      expect(kds.state.orders.single.hasActionableQuantity('tray'), isTrue);
      expect(server.count('customer_payment_displays'), displayBefore);
      expect(server.count('get_emergency_station_snapshot'), kdsBefore);
    },
  );

  test(
    'initial disconnected clients keep one-second recovery polling',
    () async {
      server.acknowledgeJoins = false;
      await Future.wait([display.start('store-1'), kds.load()]);
      final displayBefore = server.count('customer_payment_displays');
      final kdsBefore = server.count('get_emergency_station_snapshot');
      await Future<void>.delayed(const Duration(milliseconds: 2200));
      expect(server.count('customer_payment_displays') - displayBefore, 2);
      expect(server.count('get_emergency_station_snapshot') - kdsBefore, 2);
    },
  );

  test(
    'channel loss restores fast polling and reconnect reconciles data',
    () async {
      await startBoth();
      server.acknowledgeJoins = false;
      server.channelError();
      final displayBefore = server.count('customer_payment_displays');
      final kdsBefore = server.count('get_emergency_station_snapshot');
      server.displayRows['store-1'] = DisplaySyncServer.displayRow(
        'offline-update',
      );
      server.snapshot = {...server.snapshot, 'active': false};
      await waitUntil(
        () =>
            server.count('customer_payment_displays') > displayBefore &&
            server.count('get_emergency_station_snapshot') > kdsBefore,
      );
      await waitUntil(
        () =>
            display.state.snapshot?.orderId == 'offline-update' &&
            !kds.state.active,
      );
      // Use a fresh server ack on the SDK's next automatic join attempt.
      server.acknowledgeJoins = true;
      server.displayRows['store-1'] = DisplaySyncServer.displayRow(
        'reconnected',
      );
      server.snapshot = {...server.snapshot, 'active': true};
      server.channelError();
      await waitUntil(
        () =>
            display.state.snapshot?.orderId == 'reconnected' &&
            kds.state.active,
      );
    },
  );

  for (final fail in [false, true]) {
    test(
      'late display ${fail ? 'error' : 'response'} cannot overwrite realtime state',
      () async {
        await startBoth();
        final held = Completer<void>();
        server.displayFailure = fail;
        var waiting = false;
        server.beforeReply = (path) async {
          if (path == 'customer_payment_displays') {
            waiting = true;
            await held.future;
          }
        };
        final retry = display.retry();
        await waitUntil(() => waiting);
        server.change(
          'customer_payment_displays',
          DisplaySyncServer.displayRow('newer-event'),
        );
        await waitUntil(() => display.state.snapshot?.orderId == 'newer-event');
        held.complete();
        await retry;
        expect(display.state.snapshot?.orderId, 'newer-event');
        expect(display.state.error, isNull);
      },
    );
  }

  test(
    'empty/delete display event fetches current state without overlapping',
    () async {
      await startBoth();
      final held = Completer<void>();
      var waiting = false;
      server.beforeReply = (path) async {
        if (path == 'customer_payment_displays' && !waiting) {
          waiting = true;
          await held.future;
        }
      };
      final before = server.count('customer_payment_displays');
      final retry = display.retry();
      await waitUntil(() => waiting);
      server.displayRows.remove('store-1');
      server.change('customer_payment_displays', {}, type: 'DELETE');
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(server.count('customer_payment_displays') - before, 1);
      held.complete();
      await retry;
      expect(display.state.snapshot, isNull);
      expect(server.count('customer_payment_displays') - before, 2);
    },
  );

  test(
    'A to B to A ignores responses from the first store generation',
    () async {
      final held = Completer<void>();
      var waiting = false;
      server.beforeReply = (path) async {
        if (path == 'customer_payment_displays' && !waiting) {
          waiting = true;
          await held.future;
        }
      };
      final firstA = display.start('store-1');
      await waitUntil(() => waiting);
      server.displayRows['store-2'] = DisplaySyncServer.displayRow(
        'B',
        store: 'store-2',
      );
      await display.start('store-2');
      server.displayRows['store-1'] = DisplaySyncServer.displayRow('new-A');
      await display.start('store-1');
      held.complete();
      await firstA;
      expect(display.state.snapshot?.orderId, 'new-A');
      expect(
        server.subscriptions.keys.where(
          (topic) => topic.contains('customer_display'),
        ),
        hasLength(1),
      );
    },
  );

  test('wrong-store display events cannot alter current content', () async {
    await startBoth();
    server.change(
      'customer_payment_displays',
      DisplaySyncServer.displayRow('other', store: 'store-2'),
    );
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(display.state.snapshot?.orderId, 'order-1');
  });

  test('polling cannot bypass the KDS snapshot failure backoff', () async {
    await startBoth();
    server.acknowledgeJoins = false;
    server.channelError();
    await Future<void>.delayed(const Duration(milliseconds: 100));
    server.snapshotFailure = true;
    final before = server.count('get_emergency_station_snapshot');
    await kds.load();
    await Future<void>.delayed(const Duration(milliseconds: 3200));
    expect(server.count('get_emergency_station_snapshot') - before, 2);
    expect(kds.state.error, contains('EMERGENCY_SNAPSHOT_FAILED'));
    expect(kds.state.orders, isNotEmpty);
    server.snapshotFailure = false;
    await kds.load(); // A manual retry remains immediately available.
    expect(kds.state.error, isNull);
  });

  test(
    'customer display backs off failed reads and manual retry recovers',
    () async {
      server.acknowledgeJoins = false;
      await display.start('store-1');
      server.displayFailure = true;
      final before = server.count('customer_payment_displays');
      await display.retry();
      await Future<void>.delayed(const Duration(milliseconds: 3200));
      expect(server.count('customer_payment_displays') - before, 2);
      expect(display.state.snapshot, isNotNull);
      server.displayFailure = false;
      await display.retry();
      expect(display.state.error, isNull);
    },
  );

  test(
    'disposal during HTTP work stops state publication and follow-up RPCs',
    () async {
      final held = Completer<void>();
      final pending = <String>{};
      server.beforeReply = (path) async {
        if (path == 'customer_payment_displays' ||
            path == 'get_emergency_station_snapshot') {
          pending.add(path);
          await held.future;
        }
      };
      final loading = Future.wait([display.start('store-1'), kds.load()]);
      await waitUntil(() => pending.length == 2);
      display.dispose();
      kds.dispose();
      held.complete();
      await loading;
      expect(server.count('get_emergency_station_today_completed'), 0);
      final count = server.requests.values.fold(0, (sum, n) => sum + n);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      expect(server.requests.values.fold(0, (sum, n) => sum + n), count);
    },
  );

  test(
    'active v2 keeps its delta path without legacy snapshot polling',
    () async {
      server.mode = 'active';
      await kds.load();
      await waitUntil(() => server.subscriptions.length == 2);
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(server.count('get_kds_bootstrap_v2'), 1);
      expect(server.count('get_emergency_station_snapshot'), 0);
      expect(server.count('get_kds_changes_v2'), greaterThanOrEqualTo(1));
    },
  );

  test(
    'shadow mode retains its legacy snapshot and slower safety polling',
    () async {
      server.mode = 'shadow';
      await kds.load();
      await waitUntil(() => server.subscriptions.length == 3);
      await Future<void>.delayed(const Duration(milliseconds: 400));
      final before = server.count('get_emergency_station_snapshot');
      await Future<void>.delayed(const Duration(milliseconds: 2300));
      expect(server.count('get_emergency_station_snapshot'), before);
      expect(server.count('get_kds_bootstrap_v2'), 0);
    },
  );

  for (final delayWrite in [false, true]) {
    test(
      'v2 disposal during cursor ${delayWrite ? 'write' : 'read'} cannot create channels',
      () async {
        final revisions = _DelayedRevisions(delayWrite: delayWrite);
        final sync = KdsRealtimeSync(
          client: server.client,
          gateway: SupabaseKdsSyncGateway(server.client),
          config: const KdsSyncConfig(
            mode: KdsSyncMode.active,
            revision: 1,
            assigned: true,
            restaurantId: 'store-1',
            stationType: 'tray',
          ),
          revisionStore: revisions,
          onChange: (_) async {},
          onBootstrapRequired: () async {},
          onConnected: () async {},
          onError: (_, _) {},
        );
        final starting = sync.start();
        await waitUntil(() => revisions.waiting);
        await sync.dispose();
        revisions.gate.complete();
        await starting;
        expect(server.client.getChannels(), isEmpty);
        expect(server.requests, isEmpty);
      },
    );
  }
}

class _DelayedRevisions implements KdsRevisionStore {
  _DelayedRevisions({required this.delayWrite});
  final bool delayWrite;
  final gate = Completer<void>();
  bool waiting = false;

  @override
  Future<int?> read(String key) async {
    if (!delayWrite) {
      waiting = true;
      await gate.future;
    }
    return null;
  }

  @override
  Future<void> write(String key, int revision) async {
    if (delayWrite) {
      waiting = true;
      await gate.future;
    }
  }
}
