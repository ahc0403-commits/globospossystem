import 'package:excel/excel.dart';
import 'package:pos_payroll/pos_payroll.dart';

import '../../main.dart';
import 'attendance_service.dart';

export 'package:pos_payroll/pos_payroll.dart';

class PayrollService extends PosPayrollCalculator {
  PayrollService({AttendanceService? attendanceSource})
    : super(attendanceSource: attendanceSource ?? attendanceService);

  Future<List<int>> exportToExcel({
    required List<StaffPayroll> payrolls,
    required DateTime periodStart,
    required DateTime periodEnd,
  }) async {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', 'Summary');
    excel.setDefaultSheet('Summary');
    final summary = excel['Summary'];
    final details = excel['Daily Details'];

    summary.appendRow([
      TextCellValue(
        'GLOBOS Payroll Statement ${periodStart.toIso8601String().substring(0, 10)} ~ ${periodEnd.toIso8601String().substring(0, 10)} (Asia/Ho_Chi_Minh)',
      ),
    ]);
    summary.appendRow([TextCellValue('')]);
    summary.appendRow([
      TextCellValue('Employee Name'),
      TextCellValue('Work Days'),
      TextCellValue('Completed Shifts'),
      TextCellValue('Actual Hours'),
      TextCellValue('Regular Payable Hours'),
      TextCellValue('Overtime Payable Hours'),
      TextCellValue('Total Payable Hours'),
      TextCellValue('Excluded Hours'),
      TextCellValue('Night Hours'),
      TextCellValue('Holiday Hours'),
      TextCellValue('Unpaired Records'),
      TextCellValue('Late Minutes'),
      TextCellValue('Work Pay (VND)'),
      TextCellValue('Meal Allowance (VND)'),
      TextCellValue('Parking Allowance (VND)'),
      TextCellValue('Review Reference (VND)'),
      TextCellValue('Payable amount (VND)'),
    ]);

    details.appendRow([
      TextCellValue('Employee Name'),
      TextCellValue('Date'),
      TextCellValue('Clock In'),
      TextCellValue('Clock Out'),
      TextCellValue('Actual Hours'),
      TextCellValue('Regular Payable Hours'),
      TextCellValue('Overtime Payable Hours'),
      TextCellValue('Total Payable Hours'),
      TextCellValue('Excluded Hours'),
      TextCellValue('Night Hours'),
      TextCellValue('Holiday Hours'),
      TextCellValue('Work Pay (VND)'),
      TextCellValue('Meal Allowance (VND)'),
      TextCellValue('Parking Allowance (VND)'),
      TextCellValue('Payable Amount (VND)'),
      TextCellValue('Status'),
    ]);

    var totalActualMinutes = 0;
    var totalRegularMinutes = 0;
    var totalOvertimeMinutes = 0;
    var totalExcludedMinutes = 0;
    double totalAmount = 0;
    var totalWorkDays = 0;
    var totalShifts = 0;

    for (final payroll in payrolls) {
      final completedRecords = payroll.dailyRecords
          .where((record) => !record.isUnpaired)
          .toList();
      final workDays = completedRecords
          .map(
            (record) =>
                '${record.date.year}-${record.date.month}-${record.date.day}',
          )
          .toSet()
          .length;
      final nightMinutes = payroll.dailyRecords.fold<int>(
        0,
        (sum, record) => sum + record.nightMinutes,
      );
      final holidayMinutes = payroll.dailyRecords.fold<int>(
        0,
        (sum, record) => sum + record.holidayMinutes,
      );
      totalWorkDays += workDays;
      totalShifts += completedRecords.length;

      summary.appendRow([
        TextCellValue(payroll.userName),
        IntCellValue(workDays),
        IntCellValue(completedRecords.length),
        DoubleCellValue(_hoursFromMinutes(payroll.totalActualMinutes)),
        DoubleCellValue(_hoursFromMinutes(payroll.totalRegularPayableMinutes)),
        DoubleCellValue(_hoursFromMinutes(payroll.totalOvertimePayableMinutes)),
        DoubleCellValue(_hoursFromMinutes(payroll.totalPayableMinutes)),
        DoubleCellValue(_hoursFromMinutes(payroll.totalExcludedMinutes)),
        DoubleCellValue(_hoursFromMinutes(nightMinutes)),
        DoubleCellValue(_hoursFromMinutes(holidayMinutes)),
        IntCellValue(payroll.unpairedCount),
        IntCellValue(payroll.lateMinutes),
        DoubleCellValue(payroll.grossAmount),
        DoubleCellValue(payroll.totalMealAllowance),
        DoubleCellValue(payroll.totalParkingAllowance),
        DoubleCellValue(payroll.lateReviewAmount),
        DoubleCellValue(payroll.totalAmount),
      ]);

      for (final r in payroll.dailyRecords) {
        totalActualMinutes += r.actualMinutes;
        totalRegularMinutes += r.regularPayableMinutes;
        totalOvertimeMinutes += r.overtimePayableMinutes;
        totalExcludedMinutes += r.excludedMinutes;
        totalAmount += r.payableAmount;
        details.appendRow([
          TextCellValue(payroll.userName),
          TextCellValue(r.date.toIso8601String().substring(0, 10)),
          TextCellValue(r.clockIn == null ? '-' : _fmtTime(r.clockIn!)),
          TextCellValue(r.clockOut == null ? '-' : _fmtTime(r.clockOut!)),
          DoubleCellValue(_hoursFromMinutes(r.actualMinutes)),
          DoubleCellValue(_hoursFromMinutes(r.regularPayableMinutes)),
          DoubleCellValue(_hoursFromMinutes(r.overtimePayableMinutes)),
          DoubleCellValue(_hoursFromMinutes(r.payableMinutes)),
          DoubleCellValue(_hoursFromMinutes(r.excludedMinutes)),
          DoubleCellValue(_hoursFromMinutes(r.nightMinutes)),
          DoubleCellValue(_hoursFromMinutes(r.holidayMinutes)),
          DoubleCellValue(r.amount),
          DoubleCellValue(r.mealAllowance),
          DoubleCellValue(r.parkingAllowance),
          DoubleCellValue(r.payableAmount),
          TextCellValue(
            r.isUnpaired
                ? 'Review required - excluded from payroll'
                : 'Complete',
          ),
        ]);
      }
      if (payroll.lateReviewAmount > 0) {
        details.appendRow([
          TextCellValue(payroll.userName),
          TextCellValue(
            'Lateness review required: ${payroll.lateMinutes} min; '
            'reference ${payroll.lateReviewAmount.toStringAsFixed(0)} VND; '
            'no automatic wage deduction',
          ),
          TextCellValue(''),
          TextCellValue(''),
          TextCellValue(''),
          TextCellValue(''),
          TextCellValue(''),
          TextCellValue(''),
          TextCellValue(''),
          TextCellValue(''),
          TextCellValue(''),
          DoubleCellValue(0),
          DoubleCellValue(0),
          DoubleCellValue(0),
          DoubleCellValue(0),
          TextCellValue('Review required'),
        ]);
      }
    }

    summary.appendRow([
      TextCellValue('Total'),
      IntCellValue(totalWorkDays),
      IntCellValue(totalShifts),
      DoubleCellValue(_hoursFromMinutes(totalActualMinutes)),
      DoubleCellValue(_hoursFromMinutes(totalRegularMinutes)),
      DoubleCellValue(_hoursFromMinutes(totalOvertimeMinutes)),
      DoubleCellValue(
        _hoursFromMinutes(totalRegularMinutes + totalOvertimeMinutes),
      ),
      DoubleCellValue(_hoursFromMinutes(totalExcludedMinutes)),
      DoubleCellValue(
        _hoursFromMinutes(
          payrolls.fold<int>(
            0,
            (sum, payroll) =>
                sum +
                payroll.dailyRecords.fold<int>(
                  0,
                  (recordSum, record) => recordSum + record.nightMinutes,
                ),
          ),
        ),
      ),
      DoubleCellValue(
        _hoursFromMinutes(
          payrolls.fold<int>(
            0,
            (sum, payroll) =>
                sum +
                payroll.dailyRecords.fold<int>(
                  0,
                  (recordSum, record) => recordSum + record.holidayMinutes,
                ),
          ),
        ),
      ),
      IntCellValue(
        payrolls.fold(0, (sum, payroll) => sum + payroll.unpairedCount),
      ),
      IntCellValue(
        payrolls.fold(0, (sum, payroll) => sum + payroll.lateMinutes),
      ),
      DoubleCellValue(
        double.parse(
          payrolls
              .fold<double>(0, (sum, payroll) => sum + payroll.grossAmount)
              .toStringAsFixed(2),
        ),
      ),
      DoubleCellValue(
        double.parse(
          payrolls
              .fold<double>(
                0,
                (sum, payroll) => sum + payroll.totalMealAllowance,
              )
              .toStringAsFixed(2),
        ),
      ),
      DoubleCellValue(
        double.parse(
          payrolls
              .fold<double>(
                0,
                (sum, payroll) => sum + payroll.totalParkingAllowance,
              )
              .toStringAsFixed(2),
        ),
      ),
      DoubleCellValue(
        double.parse(
          payrolls
              .fold<double>(0, (sum, payroll) => sum + payroll.lateReviewAmount)
              .toStringAsFixed(2),
        ),
      ),
      DoubleCellValue(double.parse(totalAmount.toStringAsFixed(2))),
    ]);

    details.appendRow([
      TextCellValue('Total'),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
      DoubleCellValue(_hoursFromMinutes(totalActualMinutes)),
      DoubleCellValue(_hoursFromMinutes(totalRegularMinutes)),
      DoubleCellValue(_hoursFromMinutes(totalOvertimeMinutes)),
      DoubleCellValue(
        _hoursFromMinutes(totalRegularMinutes + totalOvertimeMinutes),
      ),
      DoubleCellValue(_hoursFromMinutes(totalExcludedMinutes)),
      TextCellValue(''),
      TextCellValue(''),
      DoubleCellValue(
        double.parse(
          payrolls
              .fold<double>(0, (sum, payroll) => sum + payroll.grossAmount)
              .toStringAsFixed(2),
        ),
      ),
      DoubleCellValue(
        double.parse(
          payrolls
              .fold<double>(
                0,
                (sum, payroll) => sum + payroll.totalMealAllowance,
              )
              .toStringAsFixed(2),
        ),
      ),
      DoubleCellValue(
        double.parse(
          payrolls
              .fold<double>(
                0,
                (sum, payroll) => sum + payroll.totalParkingAllowance,
              )
              .toStringAsFixed(2),
        ),
      ),
      DoubleCellValue(double.parse(totalAmount.toStringAsFixed(2))),
      TextCellValue(''),
    ]);

    for (var index = 0; index < 17; index++) {
      summary.setColumnWidth(index, index == 0 ? 28 : 18);
      summary
          .cell(CellIndex.indexByColumnRow(columnIndex: index, rowIndex: 2))
          .cellStyle = CellStyle(
        bold: true,
        backgroundColorHex: ExcelColor.blue50,
        textWrapping: TextWrapping.WrapText,
      );
    }
    for (var index = 0; index < 16; index++) {
      details.setColumnWidth(index, index == 0 ? 28 : 18);
      details
          .cell(CellIndex.indexByColumnRow(columnIndex: index, rowIndex: 0))
          .cellStyle = CellStyle(
        bold: true,
        backgroundColorHex: ExcelColor.blue50,
        textWrapping: TextWrapping.WrapText,
      );
    }
    summary
        .cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: 0))
        .cellStyle = CellStyle(
      bold: true,
      fontSize: 14,
    );

    final bytes = excel.encode();
    return bytes ?? <int>[];
  }

  double _hoursFromMinutes(int minutes) =>
      double.parse((minutes / 60).toStringAsFixed(2));

  String _fmtTime(DateTime d) {
    final h = d.hour.toString().padLeft(2, '0');
    final m = d.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  Future<void> savePayrollCache({
    required String storeId,
    required DateTime periodStart,
    required DateTime periodEnd,
    required List<StaffPayroll> payrolls,
  }) async {
    final payload = payrolls
        .map(
          (payroll) => {
            'user_id': payroll.userId,
            'total_hours': payroll.totalHours,
            'gross_amount': payroll.grossAmount,
            'late_minutes': payroll.lateMinutes,
            'late_review_amount': payroll.lateReviewAmount,
            'meal_allowance_amount': payroll.totalMealAllowance,
            'parking_allowance_amount': payroll.totalParkingAllowance,
            'total_amount': payroll.totalAmount,
            'breakdown': payroll.dailyRecords
                .map(
                  (record) => {
                    'date': record.date.toIso8601String().substring(0, 10),
                    'clock_in': record.clockIn?.toIso8601String(),
                    'clock_out': record.clockOut?.toIso8601String(),
                    'hours': record.hours,
                    'actual_minutes': record.actualMinutes,
                    'regular_payable_minutes': record.regularPayableMinutes,
                    'overtime_payable_minutes': record.overtimePayableMinutes,
                    'excluded_minutes': record.excludedMinutes,
                    'night_minutes': record.nightMinutes,
                    'holiday_minutes': record.holidayMinutes,
                    'night_hours': record.nightHours,
                    'holiday_hours': record.holidayHours,
                    'amount': record.amount,
                    'meal_allowance': record.mealAllowance,
                    'parking_allowance': record.parkingAllowance,
                    'payable_amount': record.payableAmount,
                  },
                )
                .toList(),
          },
        )
        .toList();

    await supabase.rpc(
      'save_payroll_cache',
      params: {
        'p_store_id': storeId,
        'p_period_start': periodStart.toIso8601String().substring(0, 10),
        'p_period_end': periodEnd.toIso8601String().substring(0, 10),
        'p_payrolls': payload,
      },
    );
  }
}

final payrollService = PayrollService();
