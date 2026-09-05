import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/kitchen/kitchen_provider.dart';
import 'helpers/display_sync_server.dart';

void main() {
  late DisplaySyncServer server;
  late KitchenNotifier kitchen;
  final queries = <Uri>[];
  final deleted = <String>{};
  var version = 1;
  String id(int i) =>
      '10000000-0000-0000-0000-${i.toString().padLeft(12, '0')}';
  setUp(() async {
    version = 1;
    queries.clear();
    deleted.clear();
    server = DisplaySyncServer();
    await server.start();
    final now = DateTime.now().toUtc().toIso8601String();
    server.responseForRequest = (request) {
      queries.add(request.uri);
      final q = request.uri.queryParameters;
      if (q['status'] == 'eq.completed') return [];
      final cursor =
          RegExp(r'id.gt.([\w-]+)').firstMatch(q['or'] ?? '')?.group(1) ??
          q['id']?.replaceFirst('gt.', '');
      final inIds = q['id']?.startsWith('in.') == true ? q['id'] : null;
      final rows =
          List.generate(
            251,
            (i) => {
              'id': id(i + 1),
              'created_at': now,
              'status': 'pending',
              'order_source': 'qr',
              'tables': {'table_number': q['restaurant_id']},
              'order_items': [
                {
                  'id': 'item-${i + 1}',
                  'created_at': now,
                  'label': 'Version $version',
                  'quantity': version,
                  'status': 'pending',
                },
              ],
            },
          ).where(
            (r) =>
                !deleted.contains(r['id']) &&
                (inIds == null || inIds.contains(r['id'] as String)) &&
                (cursor == null ||
                    cursor.startsWith('in.') ||
                    (r['id'] as String).compareTo(cursor) > 0),
          );
      return rows.take(int.parse(q['limit'] ?? '100')).toList();
    };
    kitchen = KitchenNotifier(client: server.client);
  });
  tearDown(() async {
    kitchen.dispose();
    await server.close();
  });
  Future<void> connect() async {
    await kitchen.loadOrders('store-a');
    await waitUntil(
      () =>
          server.subscriptions.keys.any(
            (key) => key.endsWith('kitchen_orders:store-a'),
          ) &&
          // Wire fixture must wait for the SDK to consume the join reply.
          // ignore: invalid_use_of_internal_member
          server.client.getChannels().any((c) => c.isJoined),
    );
    await waitUntil(() => queries.length >= 10);
    await Future<void>.delayed(const Duration(milliseconds: 50));
  }

  test(
    'a realtime burst queries only the changed ID and bounded history',
    () async {
      await connect();
      queries.clear();
      version = 2;
      for (var i = 0; i < 30; i++) {
        server.change('order_items', {'order_id': id(1), 'id': 'item-1'});
      }
      await waitUntil(
        () => kitchen.state.orders.first.items.first.quantity == 2,
      );
      await Future<void>.delayed(const Duration(milliseconds: 160));
      expect(kitchen.state.orders, hasLength(251));
      expect(queries, hasLength(2));
      expect(
        queries.where((q) => q.queryParameters['id']?.contains(id(1)) == true),
        hasLength(1),
      );
      expect(kitchen.state.orders[1].items.first.quantity, 1);
    },
  );
  test(
    'a missing changed order is removed without reloading all active orders',
    () async {
      await connect();
      deleted.add(id(1));
      queries.clear();
      await kitchen.refreshOrdersById('store-a', [id(1)]);
      expect(kitchen.state.orders, hasLength(250));
      expect(queries, hasLength(2));
    },
  );
  test(
    'store A to B to A ignores old results and recreates a live subscription',
    () async {
      await connect();
      final blocked = Completer<void>();
      final started = Completer<void>();
      var once = true;
      server.beforeReply = (path) async {
        if (path == 'orders' && once) {
          once = false;
          started.complete();
          await blocked.future;
        }
      };
      final old = kitchen.loadOrders('store-a');
      await started.future;
      final intermediate = kitchen.loadOrders('store-b');
      version = 3;
      final latest = kitchen.loadOrders('store-a');
      blocked.complete();
      await Future.wait([old, intermediate, latest]);
      expect(kitchen.state.orders.first.items.first.quantity, 3);
      await waitUntil(
        () =>
            server.subscriptions.keys.any(
              (key) => key.endsWith('kitchen_orders:store-a'),
            ) &&
            // Wait for the replacement channel, not the old server topic.
            // ignore: invalid_use_of_internal_member
            server.client.getChannels().any((c) => c.isJoined),
      );
      version = 4;
      server.change('order_items', {'order_id': id(1), 'id': 'item-1'});
      await waitUntil(
        () => kitchen.state.orders.first.items.first.quantity == 4,
      );
      expect(
        server.subscriptions.keys.where(
          (key) => key.contains('kitchen_orders'),
        ),
        hasLength(1),
      );
    },
  );
  test(
    'disposal while a response is delayed cannot create a channel',
    () async {
      final started = Completer<void>();
      final blocked = Completer<void>();
      var once = true;
      server.beforeReply = (path) async {
        if (once) {
          once = false;
          started.complete();
          await blocked.future;
        }
      };
      final pending = kitchen.loadOrders('store-a');
      await started.future;
      kitchen.dispose();
      blocked.complete();
      await pending;
      expect(server.subscriptions, isEmpty);
      // tearDown must dispose a live notifier only once.
      kitchen = KitchenNotifier(client: server.client);
    },
  );
}
