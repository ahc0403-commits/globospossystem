import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260908120000_direct_order_pilot_safety.sql';
  const sqlTestPath =
      'supabase/tests/direct_order_pilot_safety_contract_test.sql';

  test(
    'pilot safety migration keeps payment, fee, and bill gates server-side',
    () {
      final migration = File(migrationPath).readAsStringSync();
      expect(
        migration,
        contains('direct_order_sepay_one_request_per_transaction'),
      );
      expect(migration, contains('DIRECT_ORDER_VERIFIED_PAYMENT_REQUIRED'));
      expect(migration, contains('direct_order_approve_verified_payment'));
      expect(
        migration,
        contains('enqueue_direct_order_customer_receipt_after_payment'),
      );
      expect(migration, contains("delivery_payment_mode = 'customer_direct'"));
      expect(migration, contains('cash_paid_at = NULL'));
    },
  );

  test('SQL contract exercises the reported pilot failure cases', () {
    final sql = File(sqlTestPath).readAsStringSync();
    for (final scenario in [
      'image-only approval was not blocked',
      'transaction reuse was not blocked',
      'customer bill was not automatically queued',
      'customer bill retry was not idempotent',
      'customer-direct dispatch created a store cash payout',
      'later quote changed the earlier order delivery fee',
    ]) {
      expect(sql, contains(scenario));
    }
  });
}
