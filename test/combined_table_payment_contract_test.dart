import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/payment_service.dart';

void main() {
  test('combined order payment input preserves order identity and amount', () {
    const input = CombinedOrderPaymentInput(
      orderId: 'order-a1',
      amount: 123000,
    );

    expect(input.toJson(), {'order_id': 'order-a1', 'amount': 123000});
  });

  test('cashier exposes multi-table selection and combined checkout flow', () {
    final source = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();

    expect(source, contains("Key('cashier_combined_payment_mode')"));
    expect(source, contains('cashier_combined_order_'));
    expect(source, contains("Key('cashier_combined_payment_start')"));
    expect(source, contains('prepareCombinedTablePayment('));
    expect(source, contains('processCombinedTablePayment('));
    expect(source, contains('amountDue: combinedTotal'));
  });

  test('database checkout is atomic and keeps source payments auditable', () {
    final migration = File(
      'supabase/migrations/20260804090000_combined_table_payment.sql',
    ).readAsStringSync();

    expect(
      migration,
      contains('CREATE TABLE IF NOT EXISTS public.combined_payment_groups'),
    );
    expect(
      migration,
      contains('ADD COLUMN IF NOT EXISTS combined_payment_group_id uuid'),
    );
    expect(
      migration,
      contains(
        'CREATE OR REPLACE FUNCTION public.process_combined_table_payment',
      ),
    );
    expect(migration, contains('v_payment := public.process_payment('));
    expect(migration, contains("o.status <> 'serving'"));
    expect(migration, contains('ORDER BY o.id'));
    expect(migration, contains('FOR UPDATE'));
    expect(migration, contains("'process_combined_table_payment'"));
  });
}
