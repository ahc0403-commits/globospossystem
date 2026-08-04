import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('employment dates and daily allowance database contract is complete', () {
    final migration = _read(
      'supabase/migrations/20260804120000_employee_dates_daily_allowances.sql',
    );
    expect(migration, contains('probation_start_date date'));
    expect(migration, contains('employment_start_date date'));
    expect(migration, contains('employee_daily_allowances'));
    expect(migration, contains('v_meal_allowance := 25000'));
    expect(migration, contains('SPLIT_SHIFT_ATTENDANCE_INCOMPLETE'));
    expect(migration, contains('log.employee_id = p_employee_id'));
    expect(migration, isNot(contains('log.user_id = p_employee_id')));
    expect(migration, contains("IF p_employment_role <> 'full_time' THEN"));
    expect(migration, contains('UNIQUE (store_id, employee_id, work_date)'));
    expect(migration, contains("CHECK (unit IN ('g', 'ml', 'ea', 'box'))"));
  });

  test('employee, attendance, payroll, and inventory UI are connected', () {
    final staff = _read('lib/features/admin/tabs/staff_tab.dart');
    final attendance = _read('lib/features/admin/tabs/attendance_tab.dart');
    final payroll = _read('lib/core/services/payroll_service.dart');
    final photoInventory = _read(
      'lib/features/photo_inventory/photo_inventory_screen.dart',
    );
    final photoOps = _read('lib/features/photo_ops/photo_ops_screen.dart');

    expect(staff, contains("Key('staff_probation_start_date_field')"));
    expect(staff, contains("Key('staff_employment_start_date_field')"));
    expect(attendance, contains("Key('attendance_daily_allowance_dialog')"));
    expect(attendance, contains("Key('attendance_allowance_parking')"));
    expect(payroll, contains('mealAllowance'));
    expect(payroll, contains('parkingAllowance'));
    expect(payroll, contains('Payable amount (VND)'));
    expect(
      photoInventory,
      contains('parseLocalizedQuantityInput(stockController.text)'),
    );
    expect(
      photoOps,
      contains(
        'parseLocalizedQuantityInput(\n                  quantity.text,',
      ),
    );
  });

  test(
    'production deploy gate includes migration preflight and verification',
    () {
      final deploy = _read('scripts/deploy_pos_production.sh');
      expect(
        deploy,
        contains('20260804120000_employee_dates_daily_allowances.sql'),
      );
      expect(deploy, contains('preflight_employee_dates_daily_allowances.sql'));
      expect(deploy, contains('verify_employee_dates_daily_allowances.sql'));
    },
  );
}
