import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260723030000_cashier_non_revenue_checkout.sql';

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
    final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();
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

  test('discount modal blocks an empty reason', () {
    final modal = File(
      'lib/features/cashier/discount_modal.dart',
    ).readAsStringSync();

    expect(modal, contains('_reasonController.text.trim().isEmpty'));
    expect(modal, contains('cashierDiscountReasonRequired'));
  });
}
