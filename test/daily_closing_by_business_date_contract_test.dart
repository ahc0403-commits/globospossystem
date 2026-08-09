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
    final screen = File(
      'lib/features/admin/tabs/reports_tab.dart',
    ).readAsStringSync();

    expect(migration, contains('p_closing_date date DEFAULT NULL'));
    expect(migration, contains('DAILY_CLOSING_DATE_INVALID'));
    expect(migration, contains('get_daily_closing_days'));
    expect(migration, contains("dc.close_source = 'scheduled'"));
    expect(service, contains("'p_closing_date': closingDate"));
    expect(service, contains("'get_daily_closing_days'"));
    expect(screen, contains('record.isClosed'));
    expect(screen, contains('daily_closing_action_\${record.closingDate}'));
    expect(screen, isNot(contains("Key('daily_closing_submit_button')")));
  });
}
