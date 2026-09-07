import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260907100000_direct_delivery_cash_payout_daily_closing.sql';

  late String migration;

  setUpAll(() {
    migration = File(migrationPath).readAsStringSync();
  });

  test('records the delivery fee as an immutable cash payout', () {
    expect(migration, contains('cash_paid_at'));
    expect(migration, contains('DIRECT_ORDER_CASH_PAYOUT_LOCKED'));
    expect(migration, contains('p_actual_grab_fee IS NULL'));
  });

  test('subtracts the cash payout in preview and persisted closing totals', () {
    expect(
      migration,
      contains("'delivery_cash_payout', v_delivery_cash_payout"),
    );
    expect(
      migration,
      contains(
        'p_opening_cash_amount + v_payments_cash - v_delivery_cash_payout',
      ),
    );
    expect(migration, contains('cash_paid_at >= v_day_start'));
    expect(migration, contains('cash_paid_at < v_day_end'));
  });

  test('exposes the delivery payout in daily-closing history', () {
    expect(migration, contains('live_delivery_cash_payouts'));
    expect(migration, contains('delivery_cash_payout numeric'));
  });
}
