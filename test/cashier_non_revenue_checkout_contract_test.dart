import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/production_gate_test_support.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260723030000_cashier_non_revenue_checkout.sql';
  const concurrencyMigrationPath =
      'supabase/migrations/20260923010000_non_revenue_checkout_concurrency.sql';

  test('non-revenue checkout is atomic, classified, and audited', () {
    final sql = File(migrationPath).readAsStringSync();

    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.process_non_revenue_payment'),
    );
    expect(sql, contains("'staff_meal'"));
    expect(sql, contains("'influencer_invite'"));
    expect(sql, contains("'customer_recovery'"));
    expect(sql, contains("'tasting'"));
    expect(sql, contains("RAISE EXCEPTION 'NON_REVENUE_REASON_REQUIRED'"));
    expect(sql, contains("RAISE EXCEPTION 'NON_REVENUE_STAFF_REQUIRED'"));
    expect(
      sql,
      contains('PERFORM public.verify_discount_manager_pin_or_raise'),
    );
    expect(sql, contains("v_payment := public.process_payment("));
    expect(sql, contains("'SERVICE'"));
    expect(sql, contains("'process_non_revenue_payment'"));
    expect(sql, contains('payments_require_non_revenue_classification'));
  });

  test('discount reasons are required at the database boundary', () {
    final sql = File(migrationPath).readAsStringSync();

    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.require_discount_reason'),
    );
    expect(sql, contains("RAISE EXCEPTION 'DISCOUNT_REASON_REQUIRED'"));
    expect(sql, contains('order_discounts_require_reason'));
  });

  test('production deploy gate has preflight and post-apply verification', () {
    final deploy = readProductionGateContract();
    final preflight = File(
      'scripts/preflight_cashier_non_revenue_checkout.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_cashier_non_revenue_checkout.sql',
    ).readAsStringSync();

    expect(deploy, contains('20260723030000_cashier_non_revenue_checkout.sql'));
    expect(deploy, contains('preflight_cashier_non_revenue_checkout.sql'));
    expect(deploy, contains('verify_cashier_non_revenue_checkout.sql'));
    expect(
      preflight,
      contains('NON_REVENUE_PREFLIGHT_PROCESS_PAYMENT_MISSING'),
    );
    expect(
      verification,
      contains('NON_REVENUE_VERIFY_ATOMIC_RPC_CONTRACT_MISSING'),
    );
    expect(
      verification,
      contains('NON_REVENUE_VERIFY_STAFF_BACKFILL_INCOMPLETE'),
    );
  });

  test('cashier collects classification before non-revenue payment', () {
    final cashier = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();
    final provider = File(
      'lib/features/payment/payment_provider.dart',
    ).readAsStringSync();
    final service = File(
      'lib/core/services/payment_service.dart',
    ).readAsStringSync();

    expect(cashier, contains("Key('cashier_non_revenue_dialog')"));
    expect(cashier, contains("Key('cashier_non_revenue_type_input')"));
    expect(cashier, contains("Key('cashier_non_revenue_staff_input')"));
    expect(cashier, contains("Key('cashier_non_revenue_reason_input')"));
    expect(cashier, contains("Key('cashier_non_revenue_pin_input')"));
    expect(cashier, contains('role == \'cashier\' || isAdmin'));
    expect(cashier, contains('notifier.processNonRevenuePayment('));
    expect(
      provider,
      contains('Future<Map<String, dynamic>?> processNonRevenuePayment'),
    );
    expect(service, contains("'process_non_revenue_payment'"));
  });

  test('service checkout rejects stale totals and supports safe recovery', () {
    final sql = File(concurrencyMigrationPath).readAsStringSync();
    final provider = File(
      'lib/features/payment/payment_provider.dart',
    ).readAsStringSync();
    final cashier = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();

    expect(sql, contains("p_method = 'SERVICE'"));
    expect(sql, contains("DETAIL = 'SERVICE_TOTAL_CHANGED'"));
    expect(sql, contains('v_order_status IS DISTINCT FROM \'completed\''));
    expect(sql, contains('v_resuming := EXISTS'));
    expect(sql, contains('is_revenue IS DISTINCT FROM false'));
    expect(sql, contains('ORDER_NON_REVENUE_PAYMENT_STARTED'));
    expect(sql, contains('QR_ORDER_PAYMENT_IN_PROGRESS'));
    expect(provider, contains("error.details == 'SERVICE_TOTAL_CHANGED'"));
    expect(provider, contains('await loadOrders(storeId)'));
    expect(cashier, contains('_processNonRevenueWithReconfirmation'));
    expect(
      cashier,
      contains("Key('cashier_non_revenue_amount_changed_dialog')"),
    );
  });

  test('concurrency migration has production preflight and verification', () {
    final preflight = File(
      'scripts/preflight_non_revenue_checkout_concurrency.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_non_revenue_checkout_concurrency.sql',
    ).readAsStringSync();
    final rollback = File(
      'scripts/rollback_non_revenue_checkout_concurrency.sql',
    ).readAsStringSync();

    expect(
      preflight,
      contains('NON_REVENUE_CONCURRENCY_PREFLIGHT_PAYMENT_MISSING'),
    );
    expect(
      verification,
      contains('NON_REVENUE_CONCURRENCY_VERIFY_SERVICE_EXACTNESS_MISSING'),
    );
    expect(
      verification,
      contains('NON_REVENUE_CONCURRENCY_VERIFY_PRIVATE_CORE_EXPOSED'),
    );
    expect(
      rollback,
      contains('NON_REVENUE_CONCURRENCY_ROLLBACK_BACKUP_MISSING'),
    );
    expect(rollback, contains('RENAME TO add_items_to_order'));
  });

  test('discount modal blocks an empty reason', () {
    final modal = File(
      'lib/features/cashier/discount_modal.dart',
    ).readAsStringSync();

    expect(modal, contains('_reasonController.text.trim().isEmpty'));
    expect(modal, contains('cashierDiscountReasonRequired'));
  });
}
