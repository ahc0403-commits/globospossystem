import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/kitchen/kitchen_provider.dart';
import 'package:globos_pos_system/features/payment/payment_provider.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migrationPath =
      'supabase/migrations/20260710011000_manual_delivery_order_contract_fix.sql';

  test('cashier delivery order creation stays in the POS order lifecycle', () {
    final migration = readRepoFile(migrationPath);

    expect(migration, contains('public.create_delivery_order'));
    expect(migration, contains("v_actor.role <> 'cashier'"));
    expect(migration, contains('p_client_mutation_id text'));
    expect(migration, contains("'create_delivery_order'"));
    expect(migration, contains("'delivery',\n    'pending'"));
    expect(migration, contains('table_id,\n    sales_channel'));
    expect(migration, contains("ARRAY['kitchen']"));
    expect(migration, contains('print_jobs_delivery_identity'));
    expect(migration, contains("'table_number', 'DELIVERY'"));
    expect(migration, contains("'sales_channel', 'delivery'"));
    expect(migration, isNot(contains('deliberry_operational_orders')));
    expect(migration, isNot(contains('delivery_settlements')));
    expect(migration, isNot(contains('INSERT INTO public.external_sales')));
    expect(migration, isNot(contains('UPDATE public.external_sales')));
  });

  test('delivery order RPC rejects invalid or unavailable menu lines', () {
    final migration = readRepoFile(migrationPath);

    expect(migration, contains('p_items IS NULL'));
    expect(migration, contains("jsonb_typeof(p_items) <> 'array'"));
    expect(migration, contains('jsonb_array_length(p_items) = 0'));
    expect(migration, contains("item->>'quantity')::numeric NOT BETWEEN"));
    expect(migration, contains('m.restaurant_id = p_store_id'));
    expect(migration, contains('m.is_available = true'));
    expect(migration, contains("RAISE EXCEPTION 'ORDER_ITEMS_REQUIRED'"));
    expect(migration, contains("RAISE EXCEPTION 'INVALID_ORDER_ITEM_INPUT'"));
    expect(migration, contains("RAISE EXCEPTION 'MENU_ITEM_NOT_AVAILABLE'"));
  });

  test('cashier and kitchen surfaces expose delivery entry and badges', () {
    final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');
    final paymentProvider = readRepoFile(
      'lib/features/payment/payment_provider.dart',
    );
    final kitchen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');
    final kitchenProvider = readRepoFile(
      'lib/features/kitchen/kitchen_provider.dart',
    );
    final orderService = readRepoFile('lib/core/services/order_service.dart');
    final reportProvider = readRepoFile(
      'lib/features/report/report_provider.dart',
    );

    expect(cashier, contains("Key('cashier_new_delivery_order')"));
    expect(cashier, contains("Key('cashier_delivery_order_dialog')"));
    expect(cashier, contains("Key('cashier_delivery_submit')"));
    expect(cashier, contains('orderService.createDeliveryOrder('));
    expect(cashier, contains('_clientMutationId'));
    expect(cashier, contains('giao hàng giao hang'));
    expect(cashier, contains('cashier_delivery_order_badge_'));
    expect(paymentProvider, contains('sales_channel'));
    expect(paymentProvider, contains('bool get isDeliveryOrder'));
    expect(kitchenProvider, contains('sales_channel'));
    expect(kitchenProvider, contains('bool get isDeliveryOrder'));
    expect(kitchen, contains('kitchen_delivery_order_badge_'));
    expect(orderService, contains("'create_delivery_order'"));
    expect(orderService, contains("'p_client_mutation_id'"));
    expect(reportProvider, contains('deliveryRevenue += amount;'));
  });

  test(
    'delivery identity is derived from sales channel, not Deliberry source',
    () {
      final kitchenOrder = KitchenOrder(
        orderId: 'kitchen-order',
        tableNumber: 'DELIVERY',
        salesChannel: 'delivery',
        orderPurpose: 'customer',
        orderSource: 'staff',
        createdAt: DateTime.utc(2026, 7, 10),
        items: const [],
      );
      final cashierOrder = CashierOrder(
        orderId: 'cashier-order',
        tableNumber: 'DELIVERY',
        tableId: '',
        status: 'serving',
        salesChannel: 'delivery',
        orderPurpose: 'customer',
        orderSource: 'staff',
        items: const [],
        menuSubtotal: 0,
        serviceChargeTotal: 0,
        serviceItemTotal: 0,
        discountTotal: 0,
        totalAmount: 0,
        paidTotal: 0,
        paymentCount: 0,
        remainingDue: 0,
        createdAt: DateTime.utc(2026, 7, 10),
      );

      expect(kitchenOrder.isDeliveryOrder, isTrue);
      expect(kitchenOrder.isQrOrder, isFalse);
      expect(cashierOrder.isDeliveryOrder, isTrue);
      expect(cashierOrder.isQrOrder, isFalse);
    },
  );
}
