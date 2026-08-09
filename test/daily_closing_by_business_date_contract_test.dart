import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('daily closing supports past business dates and row-level status', () {
    final migration = File(
      'supabase/migrations/20260809100000_daily_closing_by_business_date.sql',
    ).readAsStringSync();
    final service = File(
      'lib/core/services/daily_closing_service.dart',
    ).readAsStringSync();
    final paymentMethodsMigration = File(
      'supabase/migrations/20260809110000_daily_closing_payment_methods.sql',
    ).readAsStringSync();
    final screen = File(
      'lib/features/admin/tabs/reports_tab.dart',
    ).readAsStringSync();

    expect(migration, contains('p_closing_date date DEFAULT NULL'));
    expect(migration, contains('DAILY_CLOSING_DATE_INVALID'));
    expect(migration, contains('get_daily_closing_days'));
    expect(migration, contains("dc.close_source = 'scheduled'"));
    expect(paymentMethodsMigration, contains('payments_bank_transfer numeric'));
    expect(
      paymentMethodsMigration,
      contains("lower(p.method) = 'banktransfer'"),
    );
    expect(
      paymentMethodsMigration,
      contains("'cash', 'card', 'creditcard', 'atm', 'banktransfer'"),
    );
    expect(service, contains("'p_closing_date': closingDate"));
    expect(service, contains("'get_daily_closing_days'"));
    expect(screen, contains('record.isClosed'));
    expect(screen, contains('record.depositTotal'));
    expect(screen, contains('record.paymentsPay'));
    expect(screen, contains('record.paymentsCard'));
    expect(screen, contains('record.paymentsBankTransfer'));
    expect(screen, contains('daily_closing_action_\${record.closingDate}'));
    expect(screen, isNot(contains("Key('daily_closing_submit_button')")));
  });
}
