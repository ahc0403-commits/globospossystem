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
        scope: PayrollScope(
          storeId: 'store',
          employeeId: 'part-timer-1',
          periodStart: DateTime(2026, 7, 1),
          periodEndExclusive: DateTime(2026, 8, 1),
          generatedAt: DateTime.utc(2026, 8, 1),
        ),
        lateMinutes: 15,
        lateReviewAmount: 0,
        dailyRecords: [
          DailyRecord(
            userId: 'part-timer-1',
            userName: 'Part Timer A',
            date: DateTime(2026, 7, 22),
            clockIn: DateTime(2026, 7, 22, 9),
            clockOut: DateTime(2026, 7, 22, 13),
            actualMinutes: 4 * 60,
            regularPayableMinutes: 4 * 60,
            overtimePayableMinutes: 0,
            amount: 120000,
            isUnpaired: false,
            nightMinutes: 0,
            holidayMinutes: 0,
            mealAllowance: 25000,
            parkingAllowance: 5000,
          ),
          DailyRecord(
            userId: 'part-timer-1',
            userName: 'Part Timer A',
            date: DateTime(2026, 7, 23),
            clockIn: DateTime(2026, 7, 23, 9),
            clockOut: null,
            actualMinutes: 0,
            regularPayableMinutes: 0,
            overtimePayableMinutes: 0,
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
      expect(summary.rows[2], hasLength(17));
      expect(details.rows[0], hasLength(16));
      expect(summary.rows[2][0]!.value.toString(), 'Employee Name');
      expect(
        summary.rows[0][0]!.value.toString(),
        contains('Asia/Ho_Chi_Minh'),
      );
      expect(summary.rows[2][3]!.value.toString(), 'Actual Hours');
      expect(summary.rows[2][5]!.value.toString(), 'Overtime Payable Hours');
      expect(summary.rows[2][13]!.value.toString(), 'Meal Allowance (VND)');
      expect(summary.rows[2][14]!.value.toString(), 'Parking Allowance (VND)');
      expect(summary.rows[2][16]!.value.toString(), 'Payable amount (VND)');
      expect(summary.rows[3][0]!.value.toString(), 'Part Timer A');
      expect(summary.rows[3][1]!.value.toString(), '1');
      expect(summary.rows[3][10]!.value.toString(), '1');
      expect(details.rows[0][15]!.value.toString(), 'Status');
      expect(details.rows[1][4]!.value.toString(), '4');
      expect(details.rows[1][7]!.value.toString(), '4');
      expect(details.rows[1][14]!.value.toString(), '150000');
      expect(details.rows[1][15]!.value.toString(), 'Complete');
      expect(
        details.rows[2][15]!.value.toString(),
        'Review required - excluded from payroll',
      );
    },
  );
}
