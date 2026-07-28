import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/providers/staff_provider.dart';

void main() {
  test('part-timer ID token uses the real final name and folds Vietnamese', () {
    expect(partTimerEmployeeNameToken('Nguyễn Quỳnh Mai'), 'Mai');
    expect(partTimerEmployeeNameToken('Hồ Thị Quỳnh Như'), 'Nhu');
    expect(partTimerEmployeeNameToken('  LÊ   ĐỨC  '), 'Duc');
  });

  test('prospective part-timer ID conflict finds an existing store ID', () {
    final existing = StaffMember(
      id: 'employee-1',
      employeeNumber: 'DA_Nhu',
      fullName: 'Hồ Thị Quỳnh Như',
      role: 'part_timer',
      isActive: true,
      createdAt: DateTime.utc(2026, 7, 28),
    );

    expect(
      findPartTimerEmployeeIdConflict(
        staff: [existing],
        fullName: 'Nguyễn Văn Như',
      )?.id,
      'employee-1',
    );
    expect(
      findPartTimerEmployeeIdConflict(
        staff: [existing],
        fullName: 'Nguyễn Quỳnh Mai',
      ),
      isNull,
    );
  });

  test('inactive historical employee still blocks a duplicate identity', () {
    final inactive = StaffMember(
      id: 'employee-old-mai',
      employeeNumber: 'DA_Mai',
      fullName: 'Nguyễn Quỳnh Mai',
      role: 'part_timer',
      isActive: false,
      createdAt: DateTime.utc(2026, 7, 1),
      phone: '0901234567',
    );

    expect(
      findDuplicateStaffMember(
        staff: [inactive],
        fullName: 'Nguyễn Quỳnh Mai',
        phone: '0901234567',
      )?.id,
      'employee-old-mai',
    );
    expect(
      findPartTimerEmployeeIdConflict(
        staff: [inactive],
        fullName: 'Another Mai',
      )?.id,
      'employee-old-mai',
    );
  });

  test('database rule is part-timer only and race-safe', () {
    final migration = File(
      'supabase/migrations/20260728050000_part_timer_employee_id.sql',
    ).readAsStringSync();

    expect(migration, contains("p_employment_role = 'part_timer'"));
    expect(migration, contains('left(upper(v_short_code), 2)'));
    expect(migration, contains("|| '_'"));
    expect(
      migration,
      contains('public.part_timer_employee_name_token(p_full_name)'),
    );
    expect(migration, contains('pg_advisory_xact_lock'));
    expect(migration, contains("RAISE EXCEPTION 'EMPLOYEE_ID_DUPLICATE'"));
    expect(migration, isNot(contains('employee.is_active = TRUE')));
    expect(
      migration,
      contains('Full-time and manager IDs keep the existing monotonic rule.'),
    );
  });

  test('employee form offers an edit path for generated ID conflicts', () {
    final staffTab = File(
      'lib/features/admin/tabs/staff_tab.dart',
    ).readAsStringSync();

    expect(staffTab, contains('findPartTimerEmployeeIdConflict'));
    expect(staffTab, contains('staffDuplicateEmployeeIdMessage'));
    expect(staffTab, contains("'staff_edit_existing_employee_action'"));
    expect(staffTab, contains("'EMPLOYEE_ID_DUPLICATE'"));
  });
}
