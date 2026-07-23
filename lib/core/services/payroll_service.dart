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
  double get totalAmount => grossAmount;
}

class PayrollService {
  Future<List<StaffPayroll>> calculatePayroll({
    required String storeId,
    required DateTime periodStart,
    required DateTime periodEnd,
  }) async {
    final logs = await attendanceService.fetchLogs(
      storeId: storeId,
      from: periodStart,
      to: periodEnd,
    );
    final holidays = await attendanceService.fetchVietnamPublicHolidays(
      from: periodStart,
      to: periodEnd,
    );

    final groupedByUser = <String, List<Map<String, dynamic>>>{};
    final userNames = <String, String>{};

    for (final row in logs) {
      final userId = row['user_id']?.toString() ?? '';
      if (userId.isEmpty) continue;
      groupedByUser.putIfAbsent(userId, () => []).add(row);
      final user = row['users'];
      if (user is Map<String, dynamic>) {
        userNames[userId] = user['full_name']?.toString() ?? 'Unknown';
      }
    }

    final result = <StaffPayroll>[];

    for (final entry in groupedByUser.entries) {
      final userId = entry.key;
      final userLogs = entry.value;
      userLogs.sort((a, b) {
        final atRaw = DateTime.tryParse(a['logged_at']?.toString() ?? '');
        final btRaw = DateTime.tryParse(b['logged_at']?.toString() ?? '');
        final at = atRaw == null
            ? DateTime.fromMillisecondsSinceEpoch(0)
            : TimeUtils.toVietnam(atRaw);
        final bt = btRaw == null
            ? DateTime.fromMillisecondsSinceEpoch(0)
            : TimeUtils.toVietnam(btRaw);
        return at.compareTo(bt);
      });

      final hourlyRule = await attendanceService.fetchHourlyPayRule(
        storeId: storeId,
        employeeId: userId,
      );
      final wageConfig = hourlyRule == null
          ? await attendanceService.fetchWageConfig(
              storeId: storeId,
              userId: userId,
            )
          : null;

      final wageType = hourlyRule == null
          ? (wageConfig?['wage_type']?.toString() ?? 'hourly')
          : 'hourly';
      final hourlyRate =
          double.tryParse(
            '${hourlyRule?['hourly_rate'] ?? wageConfig?['hourly_rate'] ?? 0}',
          ) ??
          0;
      final shiftRates = (wageConfig?['shift_rates'] is List)
          ? List<Map<String, dynamic>>.from(
              (wageConfig!['shift_rates'] as List).map(
                (e) => Map<String, dynamic>.from(e as Map),
              ),
            )
          : const <Map<String, dynamic>>[];

      final pairs = pairLogs(userLogs);
      final records = <DailyRecord>[];
      var lateMinutes = 0;
      final lateDatesCounted = <DateTime>{};
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
        final hours = (clockIn != null && clockOut != null)
            ? max(0, clockOut.difference(clockIn).inMinutes) / 60.0
            : 0.0;

        double amount = 0;
        double nightHours = 0;
        double holidayHours = 0;
        if (clockIn != null && clockOut != null) {
          if (wageType == 'shift') {
            amount = calcShiftAmount(clockIn, clockOut, shiftRates);
          } else if (hourlyRule != null) {
            final calculation = calcRuleBasedHourlyAmount(
              clockIn: clockIn,
              clockOut: clockOut,
              hourlyRate: hourlyRate,
              nightStartMinute: nightStart,
              nightMultiplier: nightMultiplier,
              holidayMultiplier: holidayMultiplier,
              excludeSunday: excludeSunday,
              holidays: holidays,
            );
            amount = calculation.amount;
            nightHours = calculation.nightHours;
            holidayHours = calculation.holidayHours;
          } else {
            amount = calcHourlyAmount(hours, hourlyRate);
          }
        }

        if (hourlyRule != null &&
            clockIn != null &&
            lateDatesCounted.add(date)) {
          final clockInMinute = clockIn.hour * 60 + clockIn.minute;
          lateMinutes += max(0, clockInMinute - scheduledStart);
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
          ),
        );
      }

      if (records.isNotEmpty) {
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
    DateTime? pendingIn;

    for (final row in logs) {
      final type = row['type']?.toString().toLowerCase();
      final raw = DateTime.tryParse(row['logged_at']?.toString() ?? '');
      if (raw == null) continue;
      final dt = TimeUtils.toVietnam(raw);

      if (type == 'clock_in') {
        if (pendingIn != null) {
          pairs.add((pendingIn, null));
        }
        pendingIn = dt;
      } else if (type == 'clock_out') {
        if (pendingIn == null) {
          pairs.add((null, dt));
        } else {
          pairs.add((pendingIn, dt));
          pendingIn = null;
        }
      }
    }

    if (pendingIn != null) {
      pairs.add((pendingIn, null));
    }

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
        DoubleCellValue(payroll.lateReviewAmount),
        DoubleCellValue(payroll.totalAmount),
      ]);

      for (final r in payroll.dailyRecords) {
        totalHours += r.hours;
        totalAmount += r.amount;
        details.appendRow([
          TextCellValue(payroll.userName),
          TextCellValue(r.date.toIso8601String().substring(0, 10)),
          TextCellValue(r.clockIn == null ? '-' : _fmtTime(r.clockIn!)),
          TextCellValue(r.clockOut == null ? '-' : _fmtTime(r.clockOut!)),
          DoubleCellValue(r.hours),
          DoubleCellValue(r.nightHours),
          DoubleCellValue(r.holidayHours),
          DoubleCellValue(r.amount),
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
      DoubleCellValue(double.parse(totalAmount.toStringAsFixed(2))),
      TextCellValue(''),
    ]);

    for (var index = 0; index < 11; index++) {
      summary.setColumnWidth(index, index == 0 ? 28 : 18);
      summary
          .cell(CellIndex.indexByColumnRow(columnIndex: index, rowIndex: 2))
          .cellStyle = CellStyle(
        bold: true,
        backgroundColorHex: ExcelColor.blue50,
        textWrapping: TextWrapping.WrapText,
      );
    }
    for (var index = 0; index < 9; index++) {
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
