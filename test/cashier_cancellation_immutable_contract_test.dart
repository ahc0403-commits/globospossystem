import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260807170000_cashier_cancellation_immutable_ledger.sql';

  test('cashier UI exposes unpaid order and menu item cancellation', () {
    final source = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();

    expect(source, contains("role == 'cashier' || isAdmin"));
    expect(source, contains('order.paymentCount == 0'));
    expect(source, contains("'cashier_cancel_order_item_\${item.id}'"));
    expect(source, contains('onCancelOrderItem'));
  });

  test('payment notifier routes item cancellation through the server RPC', () {
    final source = File(
      'lib/features/payment/payment_provider.dart',
    ).readAsStringSync();

    expect(source, contains('Future<bool> cancelOrderItem'));
    expect(source, contains('orderService.cancelOrderItem'));
  });

  test('cancellation amounts are server-calculated and append-only', () {
    final migration = File(migrationPath).readAsStringSync();

    expect(migration, contains("'waiter', 'cashier', 'admin'"));
    expect(migration, contains('ORDER_HAS_PAYMENTS_USE_ADJUSTMENT'));
    expect(migration, contains('order_cancellation_ledger_immutable'));
    expect(migration, contains('BEFORE UPDATE OR DELETE'));
    expect(migration, contains('REVOKE ALL ON TABLE'));
    expect(migration, contains('v_item.unit_price * v_item.quantity'));
    expect(migration, contains('RETURNING id INTO v_ledger_id'));
  });
}
