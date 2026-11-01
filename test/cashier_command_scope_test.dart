import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/order_service.dart';
import 'package:globos_pos_system/features/order/order_model.dart';
import 'package:globos_pos_system/features/payment/payment_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Orders extends OrderService {
  final done = Completer<void>();
  var calls = 0;
  Future<void> execute() async {
    calls++;
    await done.future;
  }

  @override
  Future<void> cancelOrderItem({
    required String itemId,
    required String storeId,
  }) => execute();
  @override
  Future<void> restoreCancelledOrderItem({
    required String itemId,
    required String storeId,
  }) => execute();
  @override
  Future<Map<String, dynamic>> restoreCancelledOrder({
    required String orderId,
    required String storeId,
  }) async {
    await execute();
    return {'id': orderId};
  }

  @override
  Future<Map<String, dynamic>> cancelItemQuantity({
    required String storeId,
    required String itemId,
    required int expectedQuantity,
    required int newQuantity,
    required String operationId,
  }) async {
    await execute();
    return {'operation_id': operationId};
  }

  @override
  Future<void> restoreItemQuantity({
    required String storeId,
    required String operationId,
  }) => execute();
  @override
  Future<Map<String, dynamic>> moveOrderItems({
    required String storeId,
    required String orderId,
    required String targetTableId,
    required List<Map<String, dynamic>> items,
    required String operationId,
  }) async {
    await execute();
    return {'target_order_id': 'destination'};
  }
}

class _Cashier extends PaymentNotifier {
  _Cashier(SupabaseClient client, OrderService orders)
    : super(client: client, orders: orders);
  @override
  Future<void> subscribeRealtime(String storeId) async {}
}

void main() {
  late SupabaseClient client;
  late _Orders orders;
  late _Cashier cashier;
  var failReads = false;
  final stores = <String>[];
  setUp(() async {
    failReads = false;
    stores.clear();
    orders = _Orders();
    client = SupabaseClient(
      'http://fixture.invalid',
      'fixture',
      httpClient: MockClient((request) async {
        final store =
            request.url.queryParameters['restaurant_id'] ??
            request.url.queryParameters['id'];
        if (store != null) stores.add(store);
        if (failReads) {
          return http.Response(
            jsonEncode({'message': 'read unavailable', 'code': 'PGRST000'}),
            503,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        return http.Response(
          request.url.path.endsWith('/restaurants')
              ? jsonEncode({'vat_pricing_mode': 'exclusive', 'brands': null})
              : '[]',
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    cashier = _Cashier(client, orders);
    await cashier.loadOrders('a');
    stores.clear();
  });
  tearDown(() async {
    if (cashier.mounted) cashier.dispose();
    await client.dispose();
  });
  const item = OrderItem(
    id: 'item',
    menuItemId: 'menu',
    label: 'dish',
    unitPrice: 100,
    quantity: 2,
    status: 'ready',
    itemType: 'menu_item',
  );
  final commands = <String, Future<bool> Function(_Cashier)>{
    'cancel line': (n) => n.cancelOrderItem('item', 'a'),
    'restore line': (n) => n.restoreCancelledOrderItem('item', 'a'),
    'restore order': (n) => n.restoreCancelledOrder('order', 'a'),
    'cancel quantity': (n) => n.cancelItemQuantity(
      storeId: 'a',
      item: item,
      newQuantity: 1,
      operationId: 'original',
    ),
    'restore quantity': (n) => n.restoreItemQuantity('a', 'original'),
    'move lines': (n) => n.moveOrderItems(
      storeId: 'a',
      orderId: 'order',
      targetTableId: 'table',
      items: [
        {'item_id': 'item', 'quantity': 1},
      ],
      operationId: 'original',
    ),
  };
  for (final command in commands.entries) {
    test(
      '${command.key}: confirmed write survives failed refresh without replay',
      () async {
        final result = command.value(cashier);
        expect(orders.calls, 1);
        failReads = true;
        orders.done.complete();
        expect(await result, isTrue);
        expect(orders.calls, 1);
        expect(cashier.state.isProcessing, isFalse);
        expect(cashier.state.error, contains('Failed to load payable orders'));
      },
    );
    test(
      '${command.key}: late confirmation cannot switch B back to A',
      () async {
        final result = command.value(cashier);
        await cashier.loadOrders('b');
        stores.clear();
        orders.done.complete();
        expect(await result, isTrue);
        expect(stores, isEmpty);
        expect(cashier.state.error, isNull);
        expect(cashier.state.isProcessing, isFalse);
      },
    );
  }
  test(
    'an old rejection cannot overwrite a later store or replay a write',
    () async {
      final result = cashier.cancelOrderItem('item', 'a');
      await cashier.loadOrders('b');
      stores.clear();
      orders.done.completeError(
        const PostgrestException(message: 'CASHIER_ITEM_CHANGED'),
      );
      expect(await result, isFalse);
      expect(orders.calls, 1);
      expect(stores, isEmpty);
      expect(cashier.state.error, isNull);
    },
  );
  test(
    'confirmed command still returns true after notifier disposal',
    () async {
      final result = cashier.cancelOrderItem('item', 'a');
      cashier.dispose();
      orders.done.complete();
      expect(await result, isTrue);
      expect(orders.calls, 1);
    },
  );
  test(
    'duplicate click and a command for another active store are rejected before RPC',
    () async {
      final result = cashier.cancelOrderItem('item', 'a');
      expect(await cashier.cancelOrderItem('item', 'a'), isFalse);
      orders.done.complete();
      expect(await result, isTrue);
      await cashier.loadOrders('b');
      expect(await cashier.cancelOrderItem('item', 'a'), isFalse);
      expect(orders.calls, 1);
    },
  );
}
