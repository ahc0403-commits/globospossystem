import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late String migration;

  setUpAll(() {
    migration = File(
      'supabase/migrations/20260810130000_split_shift_attendance.sql',
    ).readAsStringSync();
  });

  test('serializes employee attendance submissions before validation', () {
    expect(migration, contains('FOR UPDATE;'));
    expect(
      migration.indexOf('FOR UPDATE;'),
      lessThan(migration.indexOf('FROM public.attendance_logs al')),
    );
  });

  test('removes the one-clock-in-per-day guard', () {
    expect(migration, isNot(contains('v_has_clock_in_today')));
    expect(migration, isNot(contains('ATTENDANCE_ALREADY_CLOCKED_IN_TODAY')));
  });

  test('blocks repeated events but permits split and overnight shifts', () {
    expect(
      migration,
      contains("RAISE EXCEPTION 'ATTENDANCE_ALREADY_CLOCKED_IN'"),
    );
    expect(
      migration,
      contains("RAISE EXCEPTION 'ATTENDANCE_ALREADY_CLOCKED_OUT'"),
    );
    expect(
      migration,
      contains("RAISE EXCEPTION 'ATTENDANCE_CLOCK_IN_REQUIRED'"),
    );

    // Only the latest event controls the open shift. A clock-out can therefore
    // be followed by another same-day clock-in, while duplicate taps remain
    // blocked by the employee row lock and alternating-event checks.
    expect(
      migration,
      contains(
        "IF p_type = 'clock_in' THEN\n"
        "    IF v_last_type = 'clock_in' THEN",
      ),
    );
    expect(migration, contains("IF v_last_type = 'clock_out' THEN"));
  });
}
