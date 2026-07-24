import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/attendance_service.dart';

void main() {
  test('attendance screens keep only the latest ten records', () {
    expect(attendanceScreenRecordLimit, 10);
  });

  test('employee attendance row exposes the store employee name', () {
    final row = normalizeAttendanceLogRow({
      'id': 'log-1',
      'restaurant_id': 'store-1',
      'user_id': null,
      'employee_id': 'employee-1',
      'type': 'clock_in',
      'logged_at': '2026-07-24T02:10:53Z',
      'employee': {
        'id': 'employee-1',
        'employee_number': 'NZ101',
        'full_name': 'Nguyen Van An',
        'employment_role': 'part_timer',
      },
      'legacy_user': null,
    });

    expect(row['user_id'], 'employee-1');
    expect(row['employee_number'], 'NZ101');
    expect(row['users'], {
      'id': 'employee-1',
      'full_name': 'Nguyen Van An',
      'role': 'part_timer',
    });
  });

  test('legacy restaurant attendance row keeps the user name', () {
    final row = normalizeAttendanceLogRow({
      'id': 'log-2',
      'restaurant_id': 'store-1',
      'user_id': 'user-1',
      'employee_id': null,
      'type': 'clock_out',
      'logged_at': '2026-07-24T10:00:00Z',
      'employee': null,
      'legacy_user': {
        'id': 'user-1',
        'full_name': 'Tran Thi Binh',
        'role': 'cashier',
      },
    });

    expect(row['user_id'], 'user-1');
    expect(row['users'], {
      'id': 'user-1',
      'full_name': 'Tran Thi Binh',
      'role': 'cashier',
    });
  });
}
