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
    final pinService = readRepoFile('lib/core/services/pin_service.dart');

    expect(
      attendanceTab,
      contains('title: context.l10n.attendanceManagementTitle'),
    );
    expect(attendanceTab, contains('label: context.l10n.payrollPreview'));
    expect(attendanceTab, contains('label: context.l10n.download'));
    expect(
      attendanceTab,
      contains('title: context.l10n.attendancePayrollSummaryTitle'),
    );
    expect(attendanceTab, contains('PosSplitContent('));
    expect(attendanceTab, contains('PosTableShell('));
    expect(attendanceTab, contains('compactAttendanceList'));
    expect(attendanceTab, contains('ToastResponsiveScrollBody('));
    expect(attendanceTab, contains('_attendanceDetailBody'));
    expect(attendanceTab, contains('scrollable: false'));
    expect(attendanceTab, contains('pinService.verifyPin('));
    expect(attendanceTab, contains('record.isUnpaired'));
    expect(attendanceTab, contains('payrollService.calculatePayroll('));
    expect(attendanceTab, contains('payrollService.exportToExcel('));

    expect(
      payrollService,
      contains('Future<List<StaffPayroll>> calculatePayroll'),
    );
    expect(payrollService, contains('Future<List<int>> exportToExcel'));
    expect(payrollService, contains("excel.rename('Sheet1', 'Summary')"));
    expect(payrollService, contains("final details = excel['Daily Details']"));
    expect(payrollService, contains("'Payable Amount (VND)'"));
    expect(
      pinService,
      contains('Future<bool> verifyPin(String storeId, String enteredPin)'),
    );
    expect(attendanceTab, isNot(contains('Navigator.push(')));
    expect(
      attendanceTab,
      isNot(contains('run_inventory_purchase_recommendation')),
    );
  });

  test(
    'attendance tab clears payroll preview when attendance scope changes',
    () {
      final attendanceTab = readRepoFile(
        'lib/features/admin/tabs/attendance_tab.dart',
      );

      expect(attendanceTab, contains('void _clearPayrollPreview()'));
      expect(attendanceTab, contains('_clearPayrollPreview();'));
      expect(attendanceTab, contains('_payrolls = const [];'));
    },
  );
}
