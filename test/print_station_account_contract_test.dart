import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('dedicated print station role is store scoped and printer only', () {
    final migration = File(
      'supabase/migrations/20260809090000_print_station_account_role.sql',
    ).readAsStringSync();
    final preflight = File(
      'scripts/preflight_print_station_account_role.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_print_station_account_role.sql',
    ).readAsStringSync();
    final checker = File(
      'scripts/check_pilot_auth_accounts.sh',
    ).readAsStringSync();

    expect(migration, contains("'device_print_station'"));
    expect(migration, contains("'print_station'"));
    expect(migration, contains('public.user_accessible_stores(auth.uid())'));
    expect(migration, contains("account_code = 'print'"));
    expect(migration, isNot(contains("'print_station', 'super_admin'")));
    expect(
      preflight,
      contains('PRINT_STATION_ROLE_PREFLIGHT_IDENTITY_CONFLICT'),
    );
    expect(
      verification,
      contains('PRINT_STATION_ROLE_VERIFY_QUEUE_PERMISSION_MISSING'),
    );
    expect(checker, contains("'print_station'"));
  });
}
