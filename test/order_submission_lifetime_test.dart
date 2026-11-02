import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/orders/order_intent_journal.dart';
import 'package:globos_pos_system/core/services/order_service.dart';
import 'package:globos_pos_system/core/services/operational_day_service.dart';
import 'package:globos_pos_system/features/order/order_model.dart';
import 'package:globos_pos_system/features/order/order_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'helpers/display_sync_server.dart';

class _Journal implements OrderIntentJournal {
  _Journal({this.fail = false});
  final bool fail;
  @override
  Future<List<Map<String, dynamic>>> list(
    String project,
    String actor,
    String store,
  ) async {
    if (fail) throw StateError('Owned storage unavailable');
    return [];
  }

  @override
  Future<Map<String, dynamic>?> mutate(
    String action,
    Map<String, dynamic> input,
  ) async => throw StateError('Owned storage unavailable');
}

class _BlockedService extends OrderService {
  _BlockedService(DisplaySyncServer server)
    : super(client: server.client, journal: _Journal());
  final started = Completer<void>(), done = Completer<void>();
  @override
  Future<Map<String, dynamic>> createOrder({
    required String storeId,
    required String tableId,
    required List<Map<String, dynamic>> items,
    String? clientMutationId,
    String? businessDate,
    bool Function()? isCurrent,
  }) async {
    started.complete();
    await done.future;
    return {'id': 'original-order'};
  }
}

class _RecoveringJournal extends _Journal {
  _RecoveringJournal(this.project);
  final String project;
  bool settled = false;
  @override
  Future<List<Map<String, dynamic>>> list(
    String project,
    String actor,
    String store,
  ) async => settled
      ? []
      : [
          {
            'version': 1,
            'operation': 'original',
            'project': project,
            'actor': actor,
            'store': store,
            'kind': 'create',
            'target': 'table-a',
            'payload': jsonEncode({
              'p_store_id': store,
              'p_table_id': 'table-a',
              'p_items': [
                {'menu_item_id': 'menu', 'quantity': 1},
              ],
            }),
            'createdAt': 1,
            'revision': 1,
            'phase': 'unknown',
          },
        ];
  @override
  Future<Map<String, dynamic>?> mutate(
    String action,
    Map<String, dynamic> input,
  ) async {
    expect(action, 'settle');
    settled = true;
    return null;
  }
}

void main() {
  late DisplaySyncServer server;
  late OrderNotifier orders;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    server = DisplaySyncServer();
    await server.start();
    await server.client.auth.setInitialSession(
      jsonEncode({
        'access_token': 'synthetic-actor',
        'refresh_token': 'synthetic-refresh',
        'token_type': 'bearer',
        'expires_in': 3600,
        'user': {
          'id': 'actor',
          'app_metadata': {},
          'user_metadata': {},
          'aud': 'authenticated',
          'created_at': '2026-11-01T00:00:00Z',
        },
      }),
    );
    server.responseForRequest = (r) =>
        r.uri.path.endsWith('ensure_store_operational_day') ? {} : [];
  });
  tearDown(() async {
    if (orders.mounted) orders.dispose();
    await server.close();
  });
  void configure(OrderService service) => orders = OrderNotifier(
    client: server.client,
    dayService: OperationalDayService(client: server.client),
    orders: service,
  );
  void cart() => orders.addToCart(
    const CartItem(
      menuItemId: 'menu',
      name: 'Owned fixture dish',
      price: 10000,
      quantity: 1,
    ),
  );

  test(
    'unavailable recovery storage keeps cart, sends nothing and releases submit state',
    () async {
      configure(
        OrderService(client: server.client, journal: _Journal(fail: true)),
      );
      await orders.loadActiveOrder('table-a', 'store', syncOffline: false);
      cart();
      await orders.submitOrder('store', 'table-a');
      expect(orders.state.isSubmitting, isFalse);
      expect(orders.state.cart, hasLength(1));
      expect(server.count('create_order_for_business_day'), 0);
      expect(orders.state.error, isNotNull);
    },
  );
  test(
    'switching tables releases busy state while old confirmation stays in its original view',
    () async {
      final service = _BlockedService(server);
      configure(service);
      await orders.loadActiveOrder('table-a', 'store', syncOffline: false);
      cart();
      final old = orders.submitOrder('store', 'table-a');
      await service.started.future;
      await orders.loadActiveOrder('table-b', 'store', syncOffline: false);
      final busy = orders.state.isSubmitting;
      final cartAtSwitch = orders.state.cart;
      service.done.complete();
      await old;
      expect(busy, isFalse);
      expect(cartAtSwitch, isEmpty);
      expect(orders.state.activeOrder, isNull);
    },
  );
  test(
    'damaged legacy storage cannot block receipt recovery or erase old bytes',
    () async {
      SharedPreferences.setMockInitialValues({
        'pos_offline_mutation_queue_v1': '{broken',
        'pos_offline_mutation_queue_backup_v2': '{broken',
      });
      final journal = _RecoveringJournal(server.client.rest.url);
      configure(OrderService(client: server.client, journal: journal));
      server.responseForRequest = (r) {
        if (r.uri.path.endsWith('get_order_create_receipts_v1')) {
          return [
            {'client_mutation_id': 'original', 'store_id': 'store'},
          ];
        }
        return r.uri.path.endsWith('ensure_store_operational_day') ? {} : [];
      };
      await orders.loadActiveOrder('table-a', 'store', syncOffline: false);
      await orders.syncOfflineQueue('store');
      expect(journal.settled, isTrue);
      expect(server.count('get_order_create_receipts_v1'), 1);
      expect(server.count('execute_order_command_batch_v1'), 0);
      expect(orders.state.isSyncingOfflineQueue, isFalse);
      expect(orders.state.error, 'ORDER_RECOVERY_LEGACY_REVIEW');
      expect(
        (await SharedPreferences.getInstance()).getString(
          'pos_offline_mutation_queue_v1',
        ),
        '{broken',
      );
    },
  );
}
