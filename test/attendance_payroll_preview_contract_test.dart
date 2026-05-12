import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('attendance tab exposes a read-only payroll preview first slice', () {
    final attendanceTab = readRepoFile(
      'lib/features/admin/tabs/attendance_tab.dart',
    );
    final payrollService = readRepoFile(
      'lib/core/services/payroll_service.dart',
    );

    expect(attendanceTab, contains('Preview Payroll'));
    expect(attendanceTab, contains('Export Payroll'));
    expect(attendanceTab, contains('Payroll Preview'));
    expect(
      attendanceTab,
      contains('Read-only estimate for the selected attendance period.'),
    );
    expect(attendanceTab, contains('payrollService.calculatePayroll('));
    expect(attendanceTab, contains('payrollService.exportToExcel('));

    expect(
      payrollService,
      contains('Future<List<StaffPayroll>> calculatePayroll'),
    );
    expect(payrollService, contains('Future<List<int>> exportToExcel'));
    expect(attendanceTab, isNot(contains('Navigator.push(')));
    expect(
      attendanceTab,
      isNot(contains('run_inventory_purchase_recommendation')),
    );
  });
}
