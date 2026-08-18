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
    expect(source, contains('OutlinedButton.icon('));
    expect(source, contains('cashier_combined_order_'));
    expect(source, contains("Key('cashier_combined_payment_start')"));
    expect(source, contains('prepareCombinedTablePayment('));
    expect(source, contains('processCombinedTablePayment('));
    expect(source, contains('amountDue: combinedTotal'));
    expect(source, contains("Key('cashier_combined_qr_payment_dialog')"));
    expect(source, contains('showCombinedOnCustomerDisplay('));
    expect(source, contains('enqueueCombinedReceiptPrintJob('));
    expect(source, contains('fitAllTables: true'));
  });

  test('combined checkout queues one group receipt with combined totals', () {
    final migration = File(
      'supabase/migrations/20260814170000_combined_payment_single_receipt.sql',
    ).readAsStringSync();

    expect(
      migration,
      contains(
        'CREATE OR REPLACE FUNCTION public.enqueue_combined_receipt_print_job',
      ),
    );
    expect(migration, contains("'is_combined', true"));
    expect(migration, contains("'combined_received_amount', v_received"));
    expect(migration, contains('combined_payment_group_id = v_group.id'));
    expect(
      migration,
      contains("auth.uid(), 'enqueue_combined_receipt_print_job'"),
    );
  });

  test('combined payment owns one canonical paper and digital receipt', () {
    final migration = File(
      'supabase/migrations/'
      '20260818110000_unified_combined_customer_receipt.sql',
    ).readAsStringSync();
    final cashier = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();
    final digitalService = File(
      'lib/core/services/digital_receipt_service.dart',
    ).readAsStringSync();
    final runtimeFixture = File(
      'scripts/test_unified_combined_customer_receipt_runtime.sql',
    ).readAsStringSync();

    expect(migration, contains('build_combined_customer_receipt_snapshot'));
    expect(migration, contains("'item_id', source.id"));
    expect(migration, contains("'menu_item_id', source.menu_item_id"));
    expect(migration, contains("'table_number', source.table_number"));
    expect(migration, contains('ensure_combined_digital_receipt'));
    expect(migration, contains('order_id IS NULL'));
    expect(migration, contains('digital_receipts_combined_group_canonical'));
    expect(migration, contains('show_combined_customer_receipt_display'));
    expect(cashier, contains('_prepareCombinedDigitalReceipt('));
    expect(cashier, contains('receiptAccess: combinedReceiptAccess'));
    expect(cashier, isNot(contains('receiptAccessByOrderId')));
    expect(
      digitalService,
      contains('Future<DigitalReceiptAccess> ensureCombinedAndIssue'),
    );
    expect(
      runtimeFixture,
      contains('UNIFIED_COMBINED_CUSTOMER_RECEIPT_RUNTIME_OK'),
    );
    expect(
      runtimeFixture,
      contains('COMBINED_PAPER_DIGITAL_SNAPSHOT_DIVERGED'),
    );
    expect(runtimeFixture, contains('COMBINED_LEDGER_ENTRY_COUNT_INVALID'));
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
