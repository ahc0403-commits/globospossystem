import 'dart:math';

import 'package:excel/excel.dart';

import '../../main.dart';
import 'attendance_service.dart';
import '../utils/time_utils.dart';

class DailyRecord {
  const DailyRecord({
    required this.userId,
    required this.userName,
    required this.date,
    required this.clockIn,
    required this.clockOut,
    required this.hours,
    required this.amount,
    required this.isUnpaired,
    this.nightHours = 0,
    this.holidayHours = 0,
    this.mealAllowance = 0,
    this.parkingAllowance = 0,
  });

  final String userId;
  final String userName;
  final DateTime date;
  final DateTime? clockIn;
  final DateTime? clockOut;
  final double hours;
  final double amount;
  final bool isUnpaired;
  final double nightHours;
  final double holidayHours;
  final double mealAllowance;
  final double parkingAllowance;
  double get payableAmount => amount + mealAllowance + parkingAllowance;
}

class StaffPayroll {
  const StaffPayroll({
    required this.userId,
    required this.userName,
    required this.dailyRecords,
    this.lateMinutes = 0,
    this.lateReviewAmount = 0,
  });

  final String userId;
  final String userName;
  final List<DailyRecord> dailyRecords;
  final int lateMinutes;
  final double lateReviewAmount;

  double get totalHours => dailyRecords.fold(0, (s, r) => s + r.hours);
  double get grossAmount => dailyRecords.fold(0, (s, r) => s + r.amount);
  double get totalMealAllowance =>
      dailyRecords.fold(0, (s, r) => s + r.mealAllowance);
  double get totalParkingAllowance =>
      dailyRecords.fold(0, (s, r) => s + r.parkingAllowance);
  double get totalAmount =>
      grossAmount + totalMealAllowance + totalParkingAllowance;
}

class PayrollService {
  PayrollService({AttendanceService? attendanceSource})
    : _attendanceService = attendanceSource ?? attendanceService;

  final AttendanceService _attendanceService;

  Future<List<StaffPayroll>> calculatePayroll({
    required String storeId,
    required DateTime periodStart,
    required DateTime periodEnd,
  }) async {
    final normalizedPeriodStart = DateTime(
      periodStart.year,
      periodStart.month,
      periodStart.day,
    );
    final normalizedPeriodEndExclusive = DateTime(
      periodEnd.year,
      periodEnd.month,
      periodEnd.day + 1,
    );
    final logs = await _attendanceService.fetchLogs(
      storeId: storeId,
      from: normalizedPeriodStart,
      to: normalizedPeriodEndExclusive,
    );
    final holidays = await _attendanceService.fetchVietnamPublicHolidays(
      from: normalizedPeriodStart,
      to: periodEnd,
    );
    final allowances = await _attendanceService.fetchDailyAllowances(
      storeId: storeId,
      from: normalizedPeriodStart,
      to: periodEnd,
    );
    final staff = await _attendanceService.fetchStaffList(storeId);
    final allowanceByEmployeeDate = <String, Map<String, dynamic>>{
      for (final allowance in allowances)
        '${allowance['employee_id']}|${allowance['work_date']}': allowance,
    };

    final groupedByUser = <String, List<Map<String, dynamic>>>{};
    final userNames = <String, String>{};
    final userRoles = <String, String>{};

    for (final employee in staff) {
      final userId = employee['user_id']?.toString() ?? '';
      final role = employee['role']?.toString().trim().toLowerCase() ?? '';
      if (userId.isEmpty || (role != 'part_timer' && role != 'full_time')) {
        continue;
      }
      groupedByUser.putIfAbsent(userId, () => []);
      userNames[userId] = employee['full_name']?.toString() ?? 'Unknown';
      userRoles[userId] = role;
    }

    for (final row in logs) {
      final userId = row['user_id']?.toString() ?? '';
      if (userId.isEmpty) continue;
      final user = row['users'];
      if (user is! Map) {
        continue;
      }
      final role = user['role']?.toString().trim().toLowerCase() ?? '';
      if (role != 'part_timer' && role != 'full_time') continue;
      groupedByUser.putIfAbsent(userId, () => []).add(row);
      userNames[userId] = user['full_name']?.toString() ?? 'Unknown';
      userRoles[userId] = role;
    }

    final result = <StaffPayroll>[];

    for (final entry in groupedByUser.entries) {
      final userId = entry.key;
      final userLogs = entry.value;
      final role = userRoles[userId] ?? '';
      final hourlyRule = role == 'part_timer'
          ? await _attendanceService.fetchHourlyPayRule(
              storeId: storeId,
              employeeId: userId,
            )
          : null;
      final hourlyRate =
          double.tryParse('${hourlyRule?['hourly_rate'] ?? 0}') ?? 0;

      final pairs = pairLogs(userLogs);
      final records = <DailyRecord>[];
      var lateMinutes = 0;
      final allowanceDatesApplied = <DateTime>{};
      final scheduledStart = _toMinutes(
        hourlyRule?['scheduled_start']?.toString() ?? '09:00',
      );
      final nightStart = _toMinutes(
        hourlyRule?['night_start']?.toString() ?? '22:00',
      );
      final nightMultiplier =
          double.tryParse('${hourlyRule?['night_multiplier'] ?? 1}') ?? 1;
      final holidayMultiplier =
          double.tryParse('${hourlyRule?['holiday_multiplier'] ?? 1}') ?? 1;
      final excludeSunday = hourlyRule?['exclude_sunday'] != false;
      final lateThreshold =
          int.tryParse('${hourlyRule?['late_threshold_minutes'] ?? 60}') ?? 60;
      final lateReviewMultiplier =
          double.tryParse(
            '${hourlyRule?['late_review_hourly_multiplier'] ?? 0}',
          ) ??
          0;

      for (final pair in pairs) {
        final clockIn = pair.$1;
        final clockOut = pair.$2;
        final baseTime = clockIn ?? clockOut;
        if (baseTime == null) continue;

        final date = DateTime(baseTime.year, baseTime.month, baseTime.day);
        final dateKey = date.toIso8601String().substring(0, 10);
        final allowance = allowanceByEmployeeDate['$userId|$dateKey'];
        final appliesDailyAllowance = allowanceDatesApplied.add(date);
        final mealAllowance = appliesDailyAllowance
            ? double.tryParse('${allowance?['meal_allowance_amount'] ?? 0}') ??
                  0
            : 0.0;
        final parkingAllowance = appliesDailyAllowance
            ? double.tryParse(
                    '${allowance?['parking_allowance_amount'] ?? 0}',
                  ) ??
                  0
            : 0.0;
        var hours = (clockIn != null && clockOut != null)
            ? max(0, clockOut.difference(clockIn).inMinutes) / 60.0
            : 0.0;

        double amount = 0;
        double nightHours = 0;
        double holidayHours = 0;
        if (clockIn != null && clockOut != null) {
          if (hourlyRule != null) {
            final calculation = calcScheduledRuleBasedHourlyAmount(
              clockIn: clockIn,
              clockOut: clockOut,
              configuredStartMinute: scheduledStart,
              hourlyRate: hourlyRate,
              nightStartMinute: nightStart,
              nightMultiplier: nightMultiplier,
              holidayMultiplier: holidayMultiplier,
              excludeSunday: excludeSunday,
              holidays: holidays,
            );
            amount = calculation.amount;
            hours = calculation.hours;
            nightHours = calculation.nightHours;
            holidayHours = calculation.holidayHours;
            lateMinutes += calculation.lateMinutes;
          }
        }

        records.add(
          DailyRecord(
            userId: userId,
            userName: userNames[userId] ?? 'Unknown',
            date: date,
            clockIn: clockIn,
            clockOut: clockOut,
            hours: double.parse(hours.toStringAsFixed(2)),
            amount: amount,
            isUnpaired: clockIn == null || clockOut == null,
            nightHours: nightHours,
            holidayHours: holidayHours,
            mealAllowance: mealAllowance,
            parkingAllowance: parkingAllowance,
          ),
        );
      }

      final hasPayableAllowance = records.any(
        (record) => record.mealAllowance > 0 || record.parkingAllowance > 0,
      );
      if (role == 'part_timer' || (records.isNotEmpty && hasPayableAllowance)) {
        final lateReviewAmount =
            hourlyRule != null &&
                lateMinutes >= lateThreshold &&
                lateThreshold > 0
            ? double.parse(
                (hourlyRate * lateReviewMultiplier).toStringAsFixed(2),
              )
            : 0.0;
        result.add(
          StaffPayroll(
            userId: userId,
            userName: userNames[userId] ?? 'Unknown',
            dailyRecords: records,
            lateMinutes: lateMinutes,
            lateReviewAmount: lateReviewAmount,
          ),
        );
      }
    }

    result.sort((a, b) => a.userName.compareTo(b.userName));
    return result;
  }

  List<(DateTime?, DateTime?)> pairLogs(List<Map<String, dynamic>> logs) {
    final pairs = <(DateTime?, DateTime?)>[];
    final chronologicalLogs = [...logs]
      ..sort((a, b) {
        final aTime = DateTime.tryParse(a['logged_at']?.toString() ?? '');
        final bTime = DateTime.tryParse(b['logged_at']?.toString() ?? '');
        if (aTime == null && bTime == null) return 0;
        if (aTime == null) return 1;
        if (bTime == null) return -1;
        return aTime.compareTo(bTime);
      });

    DateTime? pendingClockIn;
    DateTime? orphanClockOut;
    var lastClosedPairIndex = -1;
    var canExtendLastClockOut = false;

    void finishPendingShift() {
      if (pendingClockIn != null) {
        pairs.add((pendingClockIn, null));
      } else if (orphanClockOut != null) {
        pairs.add((null, orphanClockOut));
      }
      pendingClockIn = null;
      orphanClockOut = null;
      canExtendLastClockOut = false;
    }

    for (final row in chronologicalLogs) {
      final type = row['type']?.toString().toLowerCase();
      if (type != 'clock_in' && type != 'clock_out') continue;
      final raw = DateTime.tryParse(row['logged_at']?.toString() ?? '');
      if (raw == null) continue;
      final dt = TimeUtils.toVietnam(raw);

      if (type == 'clock_in') {
        if (pendingClockIn == null) {
          if (orphanClockOut != null) finishPendingShift();
          pendingClockIn = dt;
          canExtendLastClockOut = false;
          continue;
        }
        final activeClockIn = pendingClockIn!;
        final pendingDay = DateTime(
          activeClockIn.year,
          activeClockIn.month,
          activeClockIn.day,
        );
        final currentDay = DateTime(dt.year, dt.month, dt.day);
        if (currentDay != pendingDay) {
          finishPendingShift();
          pendingClockIn = dt;
        }
        continue;
      }

      final activeClockIn = pendingClockIn;
      if (activeClockIn != null && !dt.isBefore(activeClockIn)) {
        pairs.add((activeClockIn, dt));
        pendingClockIn = null;
        lastClosedPairIndex = pairs.length - 1;
        canExtendLastClockOut = true;
      } else if (canExtendLastClockOut && lastClosedPairIndex >= 0) {
        // Legacy duplicate check-outs are recovered by keeping the last one,
        // but a following clock-in starts a distinct split shift.
        final lastPair = pairs[lastClosedPairIndex];
        final lastClockOut = lastPair.$2;
        if (lastClockOut != null && !dt.isBefore(lastClockOut)) {
          pairs[lastClosedPairIndex] = (lastPair.$1, dt);
        }
      } else {
        orphanClockOut = dt;
      }
    }

    finishPendingShift();
    return pairs;
  }

  double calcHourlyAmount(double hours, double hourlyRate) {
    return double.parse((hours * hourlyRate).toStringAsFixed(2));
  }

  ({double amount, double nightHours, double holidayHours})
  calcRuleBasedHourlyAmount({
    required DateTime clockIn,
    required DateTime clockOut,
    required double hourlyRate,
    required int nightStartMinute,
    required double nightMultiplier,
    required double holidayMultiplier,
    required bool excludeSunday,
    required Set<DateTime> holidays,
  }) {
    final totalMinutes = max(0, clockOut.difference(clockIn).inMinutes);
    var amount = 0.0;
    var nightMinutes = 0;
    var holidayMinutes = 0;

    for (var offset = 0; offset < totalMinutes; offset++) {
      final minute = clockIn.add(Duration(minutes: offset));
      final date = DateTime(minute.year, minute.month, minute.day);
      final currentMinute = minute.hour * 60 + minute.minute;
      final isNight = currentMinute >= nightStartMinute || currentMinute < 360;
      final isHoliday =
          holidays.contains(date) &&
          !(excludeSunday && minute.weekday == DateTime.sunday);
      var multiplier = 1.0;
      if (isNight) {
        multiplier *= nightMultiplier;
        nightMinutes++;
      }
      if (isHoliday) {
        multiplier *= holidayMultiplier;
        holidayMinutes++;
      }
      amount += hourlyRate / 60 * multiplier;
    }

    return (
      amount: double.parse(amount.toStringAsFixed(2)),
      nightHours: double.parse((nightMinutes / 60).toStringAsFixed(2)),
      holidayHours: double.parse((holidayMinutes / 60).toStringAsFixed(2)),
    );
  }

  ({
    double amount,
    double hours,
    double nightHours,
    double holidayHours,
    int lateMinutes,
    int regularMinutes,
    int overtimeMinutes,
    DateTime scheduledStart,
    DateTime scheduledEnd,
  })
  calcScheduledRuleBasedHourlyAmount({
    required DateTime clockIn,
    required DateTime clockOut,
    required int configuredStartMinute,
    required double hourlyRate,
    required int nightStartMinute,
    required double nightMultiplier,
    required double holidayMultiplier,
    required bool excludeSunday,
    required Set<DateTime> holidays,
  }) {
    final workDate = DateTime(clockIn.year, clockIn.month, clockIn.day);
    final actualStartMinute = clockIn.difference(workDate).inMinutes;
    final actualEndMinute = clockOut.difference(workDate).inMinutes;
    final standardShifts = <({int start, int end})>[
      (start: 9 * 60, end: 14 * 60),
      (start: 14 * 60, end: 18 * 60),
      (start: 18 * 60, end: 22 * 60),
      (start: 9 * 60, end: 18 * 60),
      (start: 14 * 60, end: 22 * 60),
    ];
    if (!standardShifts.any((shift) => shift.start == configuredStartMinute)) {
      for (final end in [14 * 60, 18 * 60, 22 * 60]) {
        if (end > configuredStartMinute) {
          standardShifts.add((start: configuredStartMinute, end: end));
        }
      }
    }

    var selected = standardShifts.first;
    var selectedScore = 1 << 30;
    for (final shift in standardShifts) {
      final score =
          (actualStartMinute - shift.start).abs() +
          (actualEndMinute - shift.end).abs();
      final selectedUsesConfigured = selected.start == configuredStartMinute;
      final candidateUsesConfigured = shift.start == configuredStartMinute;
      if (score < selectedScore ||
          (score == selectedScore &&
              candidateUsesConfigured &&
              !selectedUsesConfigured) ||
          (score == selectedScore &&
              candidateUsesConfigured == selectedUsesConfigured &&
              shift.end > selected.end)) {
        selected = shift;
        selectedScore = score;
      }
    }

    final scheduledStart = workDate.add(Duration(minutes: selected.start));
    final scheduledEnd = workDate.add(Duration(minutes: selected.end));
    final overtimeStart = workDate.add(const Duration(hours: 22));
    final regularStart = clockIn.isAfter(scheduledStart)
        ? clockIn
        : scheduledStart;
    final regularEnd = clockOut.isBefore(scheduledEnd)
        ? clockOut
        : scheduledEnd;
    final payableOvertimeStart = clockIn.isAfter(overtimeStart)
        ? clockIn
        : overtimeStart;
    final regularMinutes = regularEnd.isAfter(regularStart)
        ? regularEnd.difference(regularStart).inMinutes
        : 0;
    final overtimeMinutes = clockOut.isAfter(payableOvertimeStart)
        ? clockOut.difference(payableOvertimeStart).inMinutes
        : 0;

    var amount = 0.0;
    var nightHours = 0.0;
    var holidayHours = 0.0;
    for (final interval in [
      (start: regularStart, end: regularEnd, minutes: regularMinutes),
      (start: payableOvertimeStart, end: clockOut, minutes: overtimeMinutes),
    ]) {
      if (interval.minutes <= 0) continue;
      final calculation = calcRuleBasedHourlyAmount(
        clockIn: interval.start,
        clockOut: interval.end,
        hourlyRate: hourlyRate,
        nightStartMinute: nightStartMinute,
        nightMultiplier: nightMultiplier,
        holidayMultiplier: holidayMultiplier,
        excludeSunday: excludeSunday,
        holidays: holidays,
      );
      amount += calculation.amount;
      nightHours += calculation.nightHours;
      holidayHours += calculation.holidayHours;
    }

    return (
      amount: double.parse(amount.toStringAsFixed(2)),
      hours: double.parse(
        ((regularMinutes + overtimeMinutes) / 60).toStringAsFixed(2),
      ),
      nightHours: double.parse(nightHours.toStringAsFixed(2)),
      holidayHours: double.parse(holidayHours.toStringAsFixed(2)),
      lateMinutes: max(0, clockIn.difference(scheduledStart).inMinutes),
      regularMinutes: regularMinutes,
      overtimeMinutes: overtimeMinutes,
      scheduledStart: scheduledStart,
      scheduledEnd: scheduledEnd,
    );
  }

  double calcShiftAmount(
    DateTime clockIn,
    DateTime clockOut,
    List<Map<String, dynamic>> shifts,
  ) {
    final inMinute = clockIn.hour * 60 + clockIn.minute;
    final outMinute = clockOut.hour * 60 + clockOut.minute;

    for (final shift in shifts) {
      final start = shift['start']?.toString() ?? '00:00';
      final end = shift['end']?.toString() ?? '23:59';
      final amount = double.tryParse('${shift['amount'] ?? 0}') ?? 0;

      final startMin = _toMinutes(start);
      final endMin = _toMinutes(end);

      if (inMinute >= startMin && outMinute <= endMin) {
        return amount;
      }
    }

    return 0;
  }

  int _toMinutes(String hhmm) {
    final p = hhmm.split(':');
    if (p.length != 2) return 0;
    final h = int.tryParse(p[0]) ?? 0;
    final m = int.tryParse(p[1]) ?? 0;
    return h * 60 + m;
  }

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
        'GLOBOS Payroll Statement ${periodStart.toIso8601String().substring(0, 10)} ~ ${periodEnd.toIso8601String().substring(0, 10)}',
      ),
    ]);
    summary.appendRow([TextCellValue('')]);
    summary.appendRow([
      TextCellValue('Employee Name'),
      TextCellValue('Work Days'),
      TextCellValue('Completed Shifts'),
      TextCellValue('Total Hours'),
      TextCellValue('Night Hours'),
      TextCellValue('Holiday Hours'),
      TextCellValue('Unpaired Records'),
      TextCellValue('Late Minutes'),
      TextCellValue('Gross Amount (VND)'),
      TextCellValue('Meal Allowance (VND)'),
      TextCellValue('Parking Allowance (VND)'),
      TextCellValue('Review Reference (VND)'),
      TextCellValue('Payable Amount (VND)'),
    ]);

    details.appendRow([
      TextCellValue('Employee Name'),
      TextCellValue('Date'),
      TextCellValue('Clock In'),
      TextCellValue('Clock Out'),
      TextCellValue('Hours (h)'),
      TextCellValue('Night hours'),
      TextCellValue('Holiday hours'),
      TextCellValue('Amount (VND)'),
      TextCellValue('Meal allowance (VND)'),
      TextCellValue('Parking allowance (VND)'),
      TextCellValue('Payable amount (VND)'),
      TextCellValue('Status'),
    ]);

    double totalHours = 0;
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
      final nightHours = payroll.dailyRecords.fold<double>(
        0,
        (sum, record) => sum + record.nightHours,
      );
      final holidayHours = payroll.dailyRecords.fold<double>(
        0,
        (sum, record) => sum + record.holidayHours,
      );
      final unpairedCount = payroll.dailyRecords
          .where((record) => record.isUnpaired)
          .length;
      totalWorkDays += workDays;
      totalShifts += completedRecords.length;

      summary.appendRow([
        TextCellValue(payroll.userName),
        IntCellValue(workDays),
        IntCellValue(completedRecords.length),
        DoubleCellValue(payroll.totalHours),
        DoubleCellValue(double.parse(nightHours.toStringAsFixed(2))),
        DoubleCellValue(double.parse(holidayHours.toStringAsFixed(2))),
        IntCellValue(unpairedCount),
        IntCellValue(payroll.lateMinutes),
        DoubleCellValue(payroll.grossAmount),
        DoubleCellValue(payroll.totalMealAllowance),
        DoubleCellValue(payroll.totalParkingAllowance),
        DoubleCellValue(payroll.lateReviewAmount),
        DoubleCellValue(payroll.totalAmount),
      ]);

      for (final r in payroll.dailyRecords) {
        totalHours += r.hours;
        totalAmount += r.payableAmount;
        details.appendRow([
          TextCellValue(payroll.userName),
          TextCellValue(r.date.toIso8601String().substring(0, 10)),
          TextCellValue(r.clockIn == null ? '-' : _fmtTime(r.clockIn!)),
          TextCellValue(r.clockOut == null ? '-' : _fmtTime(r.clockOut!)),
          DoubleCellValue(r.hours),
          DoubleCellValue(r.nightHours),
          DoubleCellValue(r.holidayHours),
          DoubleCellValue(r.amount),
          DoubleCellValue(r.mealAllowance),
          DoubleCellValue(r.parkingAllowance),
          DoubleCellValue(r.payableAmount),
          TextCellValue(r.isUnpaired ? 'Review required' : 'Complete'),
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
      DoubleCellValue(double.parse(totalHours.toStringAsFixed(2))),
      TextCellValue(''),
      TextCellValue(''),
      IntCellValue(
        payrolls.fold(
          0,
          (sum, payroll) =>
              sum +
              payroll.dailyRecords.where((record) => record.isUnpaired).length,
        ),
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
      DoubleCellValue(double.parse(totalHours.toStringAsFixed(2))),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
      DoubleCellValue(double.parse(totalAmount.toStringAsFixed(2))),
      TextCellValue(''),
    ]);

    for (var index = 0; index < 13; index++) {
      summary.setColumnWidth(index, index == 0 ? 28 : 18);
      summary
          .cell(CellIndex.indexByColumnRow(columnIndex: index, rowIndex: 2))
          .cellStyle = CellStyle(
        bold: true,
        backgroundColorHex: ExcelColor.blue50,
        textWrapping: TextWrapping.WrapText,
      );
    }
    for (var index = 0; index < 12; index++) {
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
