import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/attendance_service.dart';
import 'package:globos_pos_system/core/services/payroll_service.dart';

class _AttendanceServiceFake extends AttendanceService {
  _AttendanceServiceFake(this.logs);

  final List<Map<String, dynamic>> logs;
  DateTime? requestedFrom;
  DateTime? requestedTo;
  final List<String> requestedRuleEmployeeIds = [];

  @override
  Future<List<Map<String, dynamic>>> fetchLogs({
    required String storeId,
    required DateTime from,
    required DateTime to,
    int limit = 500,
  }) async {
    requestedFrom = from;
    requestedTo = to;
    return logs;
  }

  @override
  Future<Map<String, dynamic>?> fetchHourlyPayRule({
    required String storeId,
    required String employeeId,
  }) async {
    requestedRuleEmployeeIds.add(employeeId);
    return {
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
  }) async => {};

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

  test(
    'historical duplicate cycles cannot create two paid shifts in one day',
    () {
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

      expect(pairs, hasLength(1));
      expect(pairs.single.$1, DateTime(2026, 7, 27, 8));
      expect(pairs.single.$2, DateTime(2026, 7, 27, 13));
    },
  );
}
