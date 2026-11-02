import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/operational_day_service.dart';
import 'package:globos_pos_system/features/order/order_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/display_sync_server.dart';

void main() {
  late DisplaySyncServer server;
  late OrderNotifier orders;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    server = DisplaySyncServer();
    await server.start();
    server.responseForRequest = (request) {
      if (request.uri.path.endsWith('ensure_store_operational_day')) return {};
      final store = request.uri.queryParameters['restaurant_id'];
      return [
        {
          'id': store,
          'table_id': request.uri.queryParameters['table_id'],
          'status': 'pending',
          'order_items': <Object>[],
        },
      ];
    };
    orders = OrderNotifier(
      client: server.client,
      dayService: OperationalDayService(client: server.client),
    );
  });
  tearDown(() async {
    if (orders.mounted) orders.dispose();
    await server.close();
  });

  test(
    'store switches discard the old read and coalesce the latest target',
    () async {
      final blocked = Completer<void>(), started = Completer<void>();
      var once = true;
      server.beforeReply = (path) async {
        if (path == 'orders' && once) {
          once = false;
          started.complete();
          await blocked.future;
        }
      };
      final old = orders.loadActiveOrder('table-a', 'a', syncOffline: false);
      await started.future;
      final rest = List.generate(
        100,
        (_) => orders.loadActiveOrder('table-b', 'b', syncOffline: false),
      );
      expect(orders.state.activeOrder, isNull);
      blocked.complete();
      await Future.wait([old, ...rest]);
      expect(orders.state.activeOrder?.id, 'eq.b');
      expect(server.count('orders'), 2);
    },
  );

  test(
    'clear session invalidates in-flight data and prevents resubscription',
    () async {
      final blocked = Completer<void>(), started = Completer<void>();
      server.beforeReply = (path) async {
        if (path == 'orders') {
          started.complete();
          await blocked.future;
        }
      };
      final pending = orders.loadActiveOrder('table', 'a', syncOffline: false);
      await started.future;
      orders.clearSession();
      blocked.complete();
      await pending;
      expect(orders.state.activeOrder, isNull);
      expect(server.subscriptions, isEmpty);
    },
  );

  test(
    'completion after disposal does not mutate state or open a channel',
    () async {
      final blocked = Completer<void>(), started = Completer<void>();
      server.beforeReply = (path) async {
        if (path == 'orders') {
          started.complete();
          await blocked.future;
        }
      };
      final pending = orders.loadActiveOrder('table', 'a', syncOffline: false);
      await started.future;
      orders.dispose();
      blocked.complete();
      await pending;
      expect(server.subscriptions, isEmpty);
    },
  );
}
