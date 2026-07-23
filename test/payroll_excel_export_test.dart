import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/payroll_service.dart';

void main() {
  test(
    'payroll Excel contains employee summary and daily detail sheets',
    () async {
      final payroll = StaffPayroll(
        userId: 'part-timer-1',
        userName: 'Part Timer A',
        lateMinutes: 15,
        lateReviewAmount: 0,
        dailyRecords: [
          DailyRecord(
            userId: 'part-timer-1',
            userName: 'Part Timer A',
            date: DateTime(2026, 7, 22),
            clockIn: DateTime(2026, 7, 22, 9),
            clockOut: DateTime(2026, 7, 22, 13),
            hours: 4,
            amount: 120000,
            isUnpaired: false,
            nightHours: 0,
            holidayHours: 0,
          ),
          DailyRecord(
            userId: 'part-timer-1',
            userName: 'Part Timer A',
            date: DateTime(2026, 7, 23),
            clockIn: DateTime(2026, 7, 23, 9),
            clockOut: null,
            hours: 0,
            amount: 0,
            isUnpaired: true,
          ),
        ],
      );

      final bytes = await PayrollService().exportToExcel(
        payrolls: [payroll],
        periodStart: DateTime(2026, 7, 1),
        periodEnd: DateTime(2026, 7, 31),
      );
      final workbook = Excel.decodeBytes(bytes);

      expect(workbook.tables.keys, containsAll(['Summary', 'Daily Details']));
      final summary = workbook.tables['Summary']!;
      final details = workbook.tables['Daily Details']!;
      expect(summary.rows[2][0]!.value.toString(), 'Employee Name');
      expect(summary.rows[2][10]!.value.toString(), 'Payable Amount (VND)');
      expect(summary.rows[3][0]!.value.toString(), 'Part Timer A');
      expect(summary.rows[3][1]!.value.toString(), '1');
      expect(summary.rows[3][6]!.value.toString(), '1');
      expect(details.rows[0][8]!.value.toString(), 'Status');
      expect(details.rows[1][8]!.value.toString(), 'Complete');
      expect(details.rows[2][8]!.value.toString(), 'Review required');
    },
  );
}
