import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/attendance_service.dart';
import 'package:globos_pos_system/core/services/payroll_service.dart';
import 'package:globos_pos_system/core/utils/time_utils.dart';

class _PayrollAttendanceFixture extends AttendanceService {
  @override
  Future<List<Map<String, dynamic>>> fetchStaffList(String storeId) async => [
    {
      'user_id': 'employee-without-logs',
      'employee_number': 'BT1',
      'full_name': 'No Log Employee',
      'role': 'part_timer',
    },
  ];

  @override
  Future<List<Map<String, dynamic>>> fetchPayrollLogs({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) async => const [];

  @override
  Future<List<Map<String, dynamic>>> fetchDailyAllowances({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) async => const [];

  @override
  Future<Set<DateTime>> fetchVietnamPublicHolidays({
    required DateTime from,
    required DateTime to,
  }) async => const {};

  @override
  Future<Map<String, dynamic>?> fetchHourlyPayRule({
    required String storeId,
    required String employeeId,
  }) async => {'hourly_rate': 30000};
}

void main() {
  test('manual attendance backend and manager UI contracts are present', () {
    final migration = File(
      'supabase/migrations/20260813150000_admin_manual_attendance_entry.sql',
    ).readAsStringSync();
    final attendance = File(
      'lib/features/admin/tabs/attendance_tab.dart',
    ).readAsStringSync();

    expect(migration, contains("'store_admin', 'brand_admin'"));
    expect(migration, contains('ATTENDANCE_MANUAL_SEQUENCE_INVALID'));
    expect(migration, contains("'attendance_manual_entry'"));
    expect(migration, contains('public.user_accessible_stores(auth.uid())'));
    expect(attendance, contains("Key('attendance_manual_entry_action')"));
    expect(attendance, contains("Key('attendance_manual_entry_dialog')"));
    expect(attendance, contains("Key('attendance_export_all_payroll')"));
    expect(attendance, contains('attendancePeriodUsageHint'));
  });

  test('monthly employee attendance is scoped by store and employee', () {
    final migration = File(
      'supabase/migrations/20260814090000_employee_monthly_attendance.sql',
    ).readAsStringSync();
    final service = File(
      'lib/core/services/attendance_service.dart',
    ).readAsStringSync();

    expect(migration, contains('get_employee_attendance_logs'));
    expect(migration, contains('log.employee_id = p_employee_id'));
    expect(migration, contains('public.user_accessible_stores(auth.uid())'));
    expect(migration, contains('ATTENDANCE_VIEW_FORBIDDEN'));
    expect(service, contains("'get_employee_attendance_logs'"));
    expect(service, contains("'p_employee_id': employeeId"));
  });

  test('manual attendance requires server-side manager PIN verification', () {
    final migration = File(
      'supabase/migrations/20260814110000_manual_attendance_manager_pin.sql',
    ).readAsStringSync();
    final preflight = File(
      'scripts/preflight_manual_attendance_manager_pin.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_manual_attendance_manager_pin.sql',
    ).readAsStringSync();
    final service = File(
      'lib/core/services/attendance_service.dart',
    ).readAsStringSync();
    final attendance = File(
      'lib/features/admin/tabs/attendance_tab.dart',
    ).readAsStringSync();

    expect(migration, contains('p_manager_pin text'));
    expect(migration, contains('verify_discount_manager_pin_or_raise'));
    expect(migration, contains("'attendance_manual_entry'"));
    expect(migration, contains('DROP FUNCTION IF EXISTS'));
    expect(preflight, contains('verify_discount_manager_pin_or_raise'));
    expect(verification, contains('legacy manual attendance RPC still exists'));
    expect(service, contains("'p_manager_pin': managerPin"));
    expect(attendance, contains("Key('attendance_manual_manager_pin')"));
    expect(attendance, contains("RegExp(r'^\\d{4,8}\$')"));
  });

  test('manual attendance backfill accepts either event entry order', () {
    final migration = File(
      'supabase/migrations/20260819110000_manual_attendance_order_independent.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_manual_attendance_order_independent.sql',
    ).readAsStringSync();

    expect(migration, contains('admin_record_employee_attendance'));
    expect(migration, contains('verify_discount_manager_pin_or_raise'));
    expect(migration, contains('ATTENDANCE_MANUAL_ENTRY_FORBIDDEN'));
    expect(migration, contains('ATTENDANCE_MANUAL_TIME_INVALID'));
    expect(migration, contains('ATTENDANCE_MANUAL_TIME_DUPLICATE'));
    expect(migration, contains('ATTENDANCE_MANUAL_REASON_REQUIRED'));
    expect(migration, contains("'attendance_manual_entry'"));
    expect(migration, isNot(contains('ATTENDANCE_MANUAL_SEQUENCE_INVALID')));
    expect(migration, isNot(contains('v_previous_type')));
    expect(migration, isNot(contains('v_next_type')));
    expect(
      verification,
      contains('manual attendance RPC still enforces event sequence'),
    );
  });

  test('manual attendance audit uses the authenticated Auth user ID', () {
    final migration = File(
      'supabase/migrations/20260819123000_manual_attendance_audit_actor_fix.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_manual_attendance_audit_actor_fix.sql',
    ).readAsStringSync();

    expect(migration, contains("auth.uid(),\n    'attendance_manual_entry'"));
    expect(
      migration,
      isNot(contains("v_actor.id,\n    'attendance_manual_entry'")),
    );
    expect(migration, isNot(contains('ATTENDANCE_MANUAL_SEQUENCE_INVALID')));
    expect(
      verification,
      contains(
        'manual attendance audit actor is not the authenticated Auth user',
      ),
    );
  });

  test('manual attendance duplicate check is scoped by event type', () {
    final migration = File(
      'supabase/migrations/20260819133000_manual_attendance_duplicate_type_scope.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_manual_attendance_duplicate_type_scope.sql',
    ).readAsStringSync();

    expect(migration, contains('AND al.type = p_type'));
    expect(migration, contains('ATTENDANCE_MANUAL_TIME_DUPLICATE'));
    expect(migration, contains("auth.uid(),\n    'attendance_manual_entry'"));
    expect(migration, isNot(contains('ATTENDANCE_MANUAL_SEQUENCE_INVALID')));
    expect(
      verification,
      contains('manual attendance duplicate check is not scoped by event type'),
    );
  });

  test(
    'payroll export includes active part-timer with no attendance logs',
    () async {
      final service = PayrollService(
        attendanceSource: _PayrollAttendanceFixture(),
      );
      final payrolls = await service.calculatePayroll(
        storeId: 'store-1',
        periodStart: DateTime(2026, 8, 1),
        periodEnd: DateTime(2026, 8, 13),
      );

      expect(payrolls, hasLength(1));
      expect(payrolls.single.userName, 'No Log Employee');
      expect(payrolls.single.totalHours, 0);
      expect(payrolls.single.totalAmount, 0);

      final bytes = await service.exportToExcel(
        payrolls: payrolls,
        periodStart: DateTime(2026, 8, 1),
        periodEnd: DateTime(2026, 8, 13),
      );
      final workbook = Excel.decodeBytes(bytes);
      final summary = workbook['Summary'];
      expect(summary.rows[2][0]?.value.toString(), 'Employee Name');
      expect(summary.rows[3][0]?.value.toString(), 'No Log Employee');
      expect(summary.rows[3][3]?.value.toString(), '0');
    },
  );

  test('Vietnam manual wall time is converted to the correct UTC instant', () {
    expect(
      TimeUtils.vietnamWallTimeToUtc(DateTime(2026, 8, 13, 11, 1)),
      DateTime.utc(2026, 8, 13, 4, 1),
    );
  });
}
