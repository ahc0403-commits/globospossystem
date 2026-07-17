import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migration;
  late String provisioning;
  late String legacyProvisioning;

  setUpAll(() {
    migration = File(
      'supabase/migrations/20260717170000_workforce_fixed_accounts.sql',
    ).readAsStringSync();
    provisioning = File(
      'supabase/functions/provision-fixed-pos-account/index.ts',
    ).readAsStringSync();
    legacyProvisioning = File(
      'supabase/functions/create_staff_user/index.ts',
    ).readAsStringSync();
  });

  test('separates fixed Auth accounts from auth-less employee records', () {
    expect(
      migration,
      contains('CREATE TABLE IF NOT EXISTS public.store_employees'),
    );
    expect(migration, contains('employee_number text NOT NULL'));
    expect(migration, contains('store_employee_number_sequences'));
    expect(migration, contains("upper(v_short_code) || v_number::text"));
    expect(migration, contains('deactivate_store_employee'));
    expect(migration, isNot(contains('DELETE FROM public.store_employees')));
  });

  test('attendance and limited inventory preserve human attribution', () {
    final attendanceStart = migration.indexOf(
      'CREATE OR REPLACE FUNCTION public.record_employee_attendance',
    );
    final attendanceEnd = migration.indexOf(
      'CREATE OR REPLACE FUNCTION public.record_employee_inventory_adjustment',
      attendanceStart,
    );
    final attendanceContract = migration.substring(
      attendanceStart,
      attendanceEnd,
    );

    expect(migration, contains('record_employee_attendance'));
    expect(migration, contains('record_employee_inventory_adjustment'));
    expect(migration, contains('performed_by_employee_id'));
    expect(migration, contains("'employee_number'"));
    expect(attendanceContract, isNot(contains('p_pin')));
    expect(attendanceContract, isNot(contains('fingerprint')));
  });

  test('Office RPC exposes only allowlisted payment profile columns', () {
    final functionStart = migration.indexOf(
      'CREATE OR REPLACE FUNCTION public.office_list_employee_payment_profiles',
    );
    final functionEnd = migration.indexOf(
      'ALTER TABLE public.store_employees ENABLE ROW LEVEL SECURITY',
      functionStart,
    );
    final contract = migration.substring(functionStart, functionEnd);

    expect(contract, contains('pos_employee_id uuid'));
    expect(contract, contains('pos_store_id uuid'));
    expect(contract, contains('profile_version bigint'));
    expect(contract, contains('phone text'));
    expect(contract, contains('bank_account_number text'));
    expect(contract, contains('bank_account_holder text'));
    expect(contract, contains('is_active boolean'));
    expect(contract, isNot(contains('full_name')));
    expect(contract, isNot(contains('employment_role')));
    expect(contract, isNot(contains('attendance_logs')));
  });

  test(
    'fixed account provisioning derives globos email and stores no password',
    () {
      expect(provisioning, contains('const ACCOUNT_DOMAIN = "globos.world"'));
      expect(
        provisioning,
        contains(r'`${requirement.account_code}@${ACCOUNT_DOMAIN}`'),
      );
      expect(provisioning, contains('requirement_id'));
      expect(provisioning, isNot(contains('password: \'default')));
      expect(migration, isNot(contains('password text')));
    },
  );

  test('legacy per-person Auth provisioning is disabled by default', () {
    expect(
      legacyProvisioning,
      contains("ALLOW_LEGACY_STAFF_PROVISIONING') !== 'true'"),
    );
    expect(legacyProvisioning, contains('USE_STORE_EMPLOYEE_DIRECTORY'));
    expect(legacyProvisioning, contains('USE_FIXED_POS_ACCOUNT_PROVISIONING'));
  });
}
