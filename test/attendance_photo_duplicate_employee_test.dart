import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/providers/staff_provider.dart';

void main() {
  test(
    'employee identity matching ignores harmless formatting differences',
    () {
      final existing = StaffMember(
        id: 'employee-1',
        employeeNumber: 'BT1',
        fullName: 'Nguyễn  Văn An',
        role: 'part_timer',
        isActive: true,
        createdAt: DateTime.utc(2026, 7, 1),
        phone: '+84 090-123-4567',
        bankName: 'Vietcom Bank',
        bankAccountNumber: '123-456-789',
        bankAccountHolder: 'NGUYỄN VĂN AN',
      );

      final duplicate = findDuplicateStaffMember(
        staff: [existing],
        fullName: ' nguyễn văn an ',
        phone: '0901234567',
        bankName: 'VIETCOMBANK',
        bankAccountNumber: '123456789',
        bankAccountHolder: 'nguyễn văn an',
      );

      expect(duplicate?.id, 'employee-1');
    },
  );

  test('different employee information is not blocked', () {
    final existing = StaffMember(
      id: 'employee-1',
      employeeNumber: 'BT1',
      fullName: 'Nguyễn Văn An',
      role: 'part_timer',
      isActive: true,
      createdAt: DateTime.utc(2026, 7, 1),
      phone: '0901234567',
    );

    expect(
      findDuplicateStaffMember(
        staff: [existing],
        fullName: 'Nguyễn Văn An',
        phone: '0909999999',
      ),
      isNull,
    );
  });

  test('photo review and database duplicate guard stay wired', () {
    final attendance = File(
      'lib/features/admin/tabs/attendance_tab.dart',
    ).readAsStringSync();
    final staff = File(
      'lib/features/admin/tabs/staff_tab.dart',
    ).readAsStringSync();
    final migration = File(
      'supabase/migrations/'
      '20260728042659_attendance_photo_review_duplicate_employee_guard.sql',
    ).readAsStringSync();

    expect(attendance, contains("Key('attendance_photo_evidence_panel')"));
    expect(attendance, contains("Key('attendance_photo_dialog')"));
    expect(attendance, contains('Image.network('));
    expect(staff, contains("Key('staff_duplicate_employee_dialog')"));
    expect(staff, contains("'staff_edit_existing_employee_action'"));
    expect(migration, contains('pg_advisory_xact_lock'));
    expect(migration, contains("RAISE EXCEPTION 'EMPLOYEE_DUPLICATE'"));
    expect(
      migration,
      contains('CREATE TRIGGER store_employee_duplicate_guard_before_insert'),
    );
  });
}
