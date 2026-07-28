import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migration;

  setUpAll(() {
    migration = File(
      'supabase/migrations/20260728060000_employee_attendance_daily_guard.sql',
    ).readAsStringSync();
  });

  test('serializes employee attendance submissions before validation', () {
    expect(migration, contains('FOR UPDATE;'));
    expect(
      migration.indexOf('FOR UPDATE;'),
      lessThan(migration.indexOf('FROM public.attendance_logs al')),
    );
  });

  test('uses Vietnam date for the one-clock-in rule', () {
    expect(migration, contains("AT TIME ZONE 'Asia/Ho_Chi_Minh'"));
    expect(migration, contains('v_has_clock_in_today'));
    expect(migration, contains('::date ='));
  });

  test('blocks repeated events but permits an overnight checkout', () {
    expect(
      migration,
      contains("RAISE EXCEPTION 'ATTENDANCE_ALREADY_CLOCKED_IN_TODAY'"),
    );
    expect(
      migration,
      contains("RAISE EXCEPTION 'ATTENDANCE_ALREADY_CLOCKED_OUT_TODAY'"),
    );
    expect(
      migration,
      contains("RAISE EXCEPTION 'ATTENDANCE_CLOCK_IN_REQUIRED'"),
    );

    // The latest event controls check-out, so yesterday's open shift can
    // close after midnight; the Vietnam-date lookup blocks a second check-in.
    expect(
      migration,
      contains(
        "IF p_type = 'clock_in' THEN\n"
        "    IF v_last_type = 'clock_in' OR v_has_clock_in_today THEN",
      ),
    );
    expect(migration, contains("IF v_last_type = 'clock_out' THEN"));
  });
}
