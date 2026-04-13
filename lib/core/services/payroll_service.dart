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
  });

  final String userId;
  final String userName;
  final DateTime date;
  final DateTime? clockIn;
  final DateTime? clockOut;
  final double hours;
  final double amount;
  final bool isUnpaired;
}

class StaffPayroll {
  const StaffPayroll({
    required this.userId,
    required this.userName,
    required this.dailyRecords,
  });

  final String userId;
  final String userName;
  final List<DailyRecord> dailyRecords;

  double get totalHours => dailyRecords.fold(0, (s, r) => s + r.hours);
  double get totalAmount => dailyRecords.fold(0, (s, r) => s + r.amount);
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

      final wageConfig = await attendanceService.fetchWageConfig(
        storeId: storeId,
        userId: userId,
      );

      final wageType = wageConfig?['wage_type']?.toString() ?? 'hourly';
      final hourlyRate =
          double.tryParse('${wageConfig?['hourly_rate'] ?? 0}') ?? 0;
      final shiftRates = (wageConfig?['shift_rates'] is List)
          ? List<Map<String, dynamic>>.from(
              (wageConfig!['shift_rates'] as List).map(
                (e) => Map<String, dynamic>.from(e as Map),
              ),
            )
          : const <Map<String, dynamic>>[];

      final pairs = pairLogs(userLogs);
      final records = <DailyRecord>[];

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
        if (clockIn != null && clockOut != null) {
          if (wageType == 'shift') {
            amount = calcShiftAmount(clockIn, clockOut, shiftRates);
          } else {
            amount = calcHourlyAmount(hours, hourlyRate);
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
          ),
        );
      }

      if (records.isNotEmpty) {
        result.add(
          StaffPayroll(
            userId: userId,
            userName: userNames[userId] ?? 'Unknown',
            dailyRecords: records,
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
    final sheet = excel['Payroll Calculation'];

    sheet.appendRow([
      TextCellValue(
        'GLOBOS Payroll Statement ${periodStart.toIso8601String().substring(0, 10)} ~ ${periodEnd.toIso8601String().substring(0, 10)}',
      ),
    ]);
    sheet.appendRow([TextCellValue('')]);
    sheet.appendRow([
      TextCellValue('Employee Name'),
      TextCellValue('Date'),
      TextCellValue('Clock In'),
      TextCellValue('Clock Out'),
      TextCellValue('Hours (h)'),
      TextCellValue('Amount (VND)'),
    ]);

    double totalHours = 0;
    double totalAmount = 0;

    for (final payroll in payrolls) {
      for (final r in payroll.dailyRecords) {
        totalHours += r.hours;
        totalAmount += r.amount;
        sheet.appendRow([
          TextCellValue(payroll.userName),
          TextCellValue(r.date.toIso8601String().substring(0, 10)),
          TextCellValue(r.clockIn == null ? '-' : _fmtTime(r.clockIn!)),
          TextCellValue(r.clockOut == null ? '-' : _fmtTime(r.clockOut!)),
          DoubleCellValue(r.hours),
          DoubleCellValue(r.amount),
        ]);
      }
    }

    sheet.appendRow([
      TextCellValue('Total'),
      TextCellValue(''),
      TextCellValue(''),
      TextCellValue(''),
      DoubleCellValue(double.parse(totalHours.toStringAsFixed(2))),
      DoubleCellValue(double.parse(totalAmount.toStringAsFixed(2))),
    ]);

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
    for (final payroll in payrolls) {
      final totalHours = payroll.totalHours;
      final totalAmount = payroll.totalAmount;
      final breakdown = payroll.dailyRecords
          .map(
            (r) => {
              'date': r.date.toIso8601String().substring(0, 10),
              'clock_in': r.clockIn?.toIso8601String(),
              'clock_out': r.clockOut?.toIso8601String(),
              'hours': r.hours,
              'amount': r.amount,
            },
          )
          .toList();

      await supabase.from('payroll_records').insert({
        'restaurant_id': storeId,
        'user_id': payroll.userId,
        'period_start': periodStart.toIso8601String().substring(0, 10),
        'period_end': periodEnd.toIso8601String().substring(0, 10),
        'total_hours': totalHours,
        'total_amount': totalAmount,
        'breakdown': breakdown,
      });
    }
  }
}

final payrollService = PayrollService();
