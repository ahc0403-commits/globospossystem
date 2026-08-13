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
  Future<List<Map<String, dynamic>>> fetchLogs({
    required String storeId,
    required DateTime from,
    required DateTime to,
    int limit = 500,
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
