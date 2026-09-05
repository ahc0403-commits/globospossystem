import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/attendance_service.dart';
import 'package:globos_pos_system/core/services/payroll_service.dart';

class _AttendanceServiceFake extends AttendanceService {
  _AttendanceServiceFake(
    this.logs, {
    this.hourlyPayRule,
    this.holidays = const {},
  });

  final List<Map<String, dynamic>> logs;
  final Map<String, dynamic>? hourlyPayRule;
  final Set<DateTime> holidays;
  DateTime? requestedFrom;
  DateTime? requestedTo;
  final List<String> requestedRuleEmployeeIds = [];
  List<Map<String, dynamic>> allowances = const [];

  @override
  Future<List<Map<String, dynamic>>> fetchLogs({
    required String storeId,
    required DateTime from,
    required DateTime to,
    int limit = 500,
  }) async {
    requestedFrom = from;
    requestedTo = to;
    final rows = List<Map<String, dynamic>>.of(logs)
      ..sort((a, b) => '${b['logged_at']}'.compareTo('${a['logged_at']}'));
    return rows.take(limit).toList();
  }

  @override
  Future<List<Map<String, dynamic>>> fetchPayrollLogs({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) async {
    requestedFrom = from;
    requestedTo = to;
    return logs;
  }

  @override
  Future<List<Map<String, dynamic>>> fetchStaffList(String storeId) async {
    final staffById = <String, Map<String, dynamic>>{};
    for (final log in logs) {
      final id = log['user_id']?.toString() ?? '';
      final user = log['users'];
      if (id.isEmpty || user is! Map) continue;
      staffById[id] = {
        'user_id': id,
        'full_name': user['full_name'],
        'role': user['role'],
      };
    }
    return staffById.values.toList(growable: false);
  }

  @override
  Future<Map<String, dynamic>?> fetchHourlyPayRule({
    required String storeId,
    required String employeeId,
  }) async {
    requestedRuleEmployeeIds.add(employeeId);
    return hourlyPayRule ??
        {
          'hourly_rate': 30000,
          'scheduled_start': '09:00',
          'night_start': '22:00',
          'night_multiplier': 1.3,
          'holiday_multiplier': 3,
          'exclude_sunday': true,
          'late_threshold_minutes': 60,
          'late_review_hourly_multiplier': 2,
        };
  }

  @override
  Future<Set<DateTime>> fetchVietnamPublicHolidays({
    required DateTime from,
    required DateTime to,
  }) async => holidays;

  @override
  Future<List<Map<String, dynamic>>> fetchDailyAllowances({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) async => allowances;

  @override
  Future<Map<String, dynamic>?> fetchWageConfig({
    required String storeId,
    required String userId,
  }) {
    throw StateError(
      'Legacy wage config must not be used for store employees.',
    );
  }
}

Map<String, dynamic> _log({
  required String employeeId,
  required String name,
  required String role,
  required String type,
  required String loggedAt,
}) {
  return {
    'user_id': employeeId,
    'type': type,
    'logged_at': loggedAt,
    'users': {'full_name': name, 'role': role},
  };
}

void main() {
  test(
    'payroll includes attendance beyond the 500-row display limit',
    () async {
      final start = DateTime.utc(2026, 1, 1);
      final logs = <Map<String, dynamic>>[
        for (var day = 0; day < 251; day++) ...[
          _log(
            employeeId: 'part-timer',
            name: 'Mai',
            role: 'part_timer',
            type: 'clock_in',
            loggedAt: start
                .add(Duration(days: day, hours: 2))
                .toIso8601String(),
          ),
          _log(
            employeeId: 'part-timer',
            name: 'Mai',
            role: 'part_timer',
            type: 'clock_out',
            loggedAt: start
                .add(Duration(days: day, hours: 10))
                .toIso8601String(),
          ),
        ],
      ];
      final attendance = _AttendanceServiceFake(
        logs,
        hourlyPayRule: {
          'hourly_rate': 30000,
          'scheduled_start': '09:00',
          'exclude_sunday': false,
        },
      );
      final payroll = await PayrollService(attendanceSource: attendance)
          .calculatePayroll(
            storeId: 'store',
            periodStart: DateTime(2026, 1, 1),
            periodEnd: DateTime(2026, 1, 1).add(const Duration(days: 250)),
          );
      expect(payroll.single.dailyRecords, hasLength(251));
      expect(payroll.single.totalHours, 251 * 8);
      expect(payroll.single.totalAmount, 251 * 8 * 30000);
    },
  );

  test(
    'payroll includes the full selected end date and only part-timers',
    () async {
      final attendance = _AttendanceServiceFake([
        _log(
          employeeId: 'part-timer',
          name: 'Nguyen Quynh Mai',
          role: 'part_timer',
          type: 'clock_out',
          loggedAt: '2026-07-27T09:15:00Z',
        ),
        _log(
          employeeId: 'full-time',
          name: 'Ho Thi Quynh Nhu',
          role: 'full_time',
          type: 'clock_out',
          loggedAt: '2026-07-27T09:12:00Z',
        ),
        _log(
          employeeId: 'part-timer',
          name: 'Nguyen Quynh Mai',
          role: 'part_timer',
          type: 'clock_in',
          loggedAt: '2026-07-27T04:27:00Z',
        ),
        _log(
          employeeId: 'full-time',
          name: 'Ho Thi Quynh Nhu',
          role: 'full_time',
          type: 'clock_in',
          loggedAt: '2026-07-27T09:10:00Z',
        ),
      ]);
      final payrolls = await PayrollService(attendanceSource: attendance)
          .calculatePayroll(
            storeId: 'store',
            periodStart: DateTime(2026, 7, 27, 16),
            periodEnd: DateTime(2026, 7, 27),
          );

      expect(attendance.requestedFrom, DateTime(2026, 7, 27));
      expect(attendance.requestedTo, DateTime(2026, 7, 28));
      expect(attendance.requestedRuleEmployeeIds, ['part-timer']);
      expect(payrolls, hasLength(1));
      expect(payrolls.single.userName, 'Nguyen Quynh Mai');
      expect(payrolls.single.totalHours, 4.8);
      expect(payrolls.single.totalAmount, 144000);
    },
  );

  test(
    'split shifts clamp each attendance pair and add allowances once per day',
    () async {
      final attendance =
          _AttendanceServiceFake([
              _log(
                employeeId: 'part-timer',
                name: 'Mai',
                role: 'part_timer',
                type: 'clock_in',
                loggedAt: '2026-07-27T02:00:00Z',
              ),
              _log(
                employeeId: 'part-timer',
                name: 'Mai',
                role: 'part_timer',
                type: 'clock_out',
                loggedAt: '2026-07-27T04:00:00Z',
              ),
              _log(
                employeeId: 'part-timer',
                name: 'Mai',
                role: 'part_timer',
                type: 'clock_in',
                loggedAt: '2026-07-27T06:00:00Z',
              ),
              _log(
                employeeId: 'part-timer',
                name: 'Mai',
                role: 'part_timer',
                type: 'clock_out',
                loggedAt: '2026-07-27T08:00:00Z',
              ),
            ])
            ..allowances = [
              {
                'employee_id': 'part-timer',
                'work_date': '2026-07-27',
                'meal_allowance_amount': 25000,
                'parking_allowance_amount': 5000,
              },
            ];

      final payroll =
          (await PayrollService(attendanceSource: attendance).calculatePayroll(
            storeId: 'store',
            periodStart: DateTime(2026, 7, 27),
            periodEnd: DateTime(2026, 7, 27),
          )).single;

      expect(payroll.dailyRecords, hasLength(2));
      expect(payroll.totalHours, 3);
      expect(payroll.grossAmount, 90000);
      expect(payroll.totalMealAllowance, 25000);
      expect(payroll.totalParkingAllowance, 5000);
      expect(payroll.totalAmount, 120000);
    },
  );

  test(
    'holiday shift ignores early arrival and does not stack the night rate',
    () async {
      final attendance =
          _AttendanceServiceFake(
              [
                _log(
                  employeeId: 'part-timer',
                  name: 'Le Thi Nhu Y',
                  role: 'part_timer',
                  type: 'clock_in',
                  loggedAt: '2026-09-01T10:51:00Z',
                ),
                _log(
                  employeeId: 'part-timer',
                  name: 'Le Thi Nhu Y',
                  role: 'part_timer',
                  type: 'clock_out',
                  loggedAt: '2026-09-01T15:00:00Z',
                ),
              ],
              hourlyPayRule: {
                'hourly_rate': 25000,
                'scheduled_start': '18:00',
                'night_start': '18:00',
                'night_multiplier': 1.5,
                'holiday_multiplier': 3,
                'exclude_sunday': true,
                'late_threshold_minutes': 60,
                'late_review_hourly_multiplier': 2,
              },
              holidays: {DateTime(2026, 9, 1)},
            )
            ..allowances = [
              {
                'employee_id': 'part-timer',
                'work_date': '2026-09-01',
                'meal_allowance_amount': 0,
                'parking_allowance_amount': 3000,
              },
            ];

      final payroll =
          (await PayrollService(attendanceSource: attendance).calculatePayroll(
            storeId: 'store',
            periodStart: DateTime(2026, 9, 1),
            periodEnd: DateTime(2026, 9, 1),
          )).single;

      expect(payroll.dailyRecords.single.clockIn, DateTime(2026, 9, 1, 17, 51));
      expect(payroll.totalHours, 4);
      expect(payroll.dailyRecords.single.holidayHours, 4);
      expect(payroll.grossAmount, 300000);
      expect(payroll.totalParkingAllowance, 3000);
      expect(payroll.totalAmount, 303000);
    },
  );

  test(
    'full-time payroll includes parking only and no automatic wage',
    () async {
      final attendance =
          _AttendanceServiceFake([
              _log(
                employeeId: 'full-time',
                name: 'Nhu',
                role: 'full_time',
                type: 'clock_in',
                loggedAt: '2026-07-27T02:00:00Z',
              ),
              _log(
                employeeId: 'full-time',
                name: 'Nhu',
                role: 'full_time',
                type: 'clock_out',
                loggedAt: '2026-07-27T10:00:00Z',
              ),
            ])
            ..allowances = [
              {
                'employee_id': 'full-time',
                'work_date': '2026-07-27',
                'meal_allowance_amount': 0,
                'parking_allowance_amount': 10000,
              },
            ];

      final payroll =
          (await PayrollService(attendanceSource: attendance).calculatePayroll(
            storeId: 'store',
            periodStart: DateTime(2026, 7, 27),
            periodEnd: DateTime(2026, 7, 27),
          )).single;

      expect(attendance.requestedRuleEmployeeIds, isEmpty);
      expect(payroll.grossAmount, 0);
      expect(payroll.totalMealAllowance, 0);
      expect(payroll.totalParkingAllowance, 10000);
      expect(payroll.totalAmount, 10000);
    },
  );

  test(
    'pairing uses first clock-in and last clock-out for historical duplicates',
    () {
      final pairs = PayrollService().pairLogs([
        _log(
          employeeId: 'part-timer',
          name: 'Mai',
          role: 'part_timer',
          type: 'clock_out',
          loggedAt: '2026-07-27T09:15:23Z',
        ),
        _log(
          employeeId: 'part-timer',
          name: 'Mai',
          role: 'part_timer',
          type: 'clock_out',
          loggedAt: '2026-07-27T04:28:17Z',
        ),
        _log(
          employeeId: 'part-timer',
          name: 'Mai',
          role: 'part_timer',
          type: 'clock_in',
          loggedAt: '2026-07-27T04:27:54Z',
        ),
        _log(
          employeeId: 'part-timer',
          name: 'Mai',
          role: 'part_timer',
          type: 'clock_in',
          loggedAt: '2026-07-27T04:27:55Z',
        ),
      ]);

      expect(pairs, hasLength(1));
      expect(pairs.single.$1, DateTime(2026, 7, 27, 11, 27, 54));
      expect(pairs.single.$2, DateTime(2026, 7, 27, 16, 15, 23));
    },
  );

  test('alternating cycles create separate paid split shifts in one day', () {
    final pairs = PayrollService().pairLogs([
      _log(
        employeeId: 'part-timer',
        name: 'Mai',
        role: 'part_timer',
        type: 'clock_in',
        loggedAt: '2026-07-27T01:00:00Z',
      ),
      _log(
        employeeId: 'part-timer',
        name: 'Mai',
        role: 'part_timer',
        type: 'clock_out',
        loggedAt: '2026-07-27T03:00:00Z',
      ),
      _log(
        employeeId: 'part-timer',
        name: 'Mai',
        role: 'part_timer',
        type: 'clock_in',
        loggedAt: '2026-07-27T04:00:00Z',
      ),
      _log(
        employeeId: 'part-timer',
        name: 'Mai',
        role: 'part_timer',
        type: 'clock_out',
        loggedAt: '2026-07-27T06:00:00Z',
      ),
    ]);

    expect(pairs, hasLength(2));
    expect(pairs.first.$1, DateTime(2026, 7, 27, 8));
    expect(pairs.first.$2, DateTime(2026, 7, 27, 10));
    expect(pairs.last.$1, DateTime(2026, 7, 27, 11));
    expect(pairs.last.$2, DateTime(2026, 7, 27, 13));
  });
}
