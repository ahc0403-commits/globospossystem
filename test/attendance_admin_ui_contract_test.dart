import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('attendance admin surface stays record-review first', () {
    final source = readRepoFile('lib/features/admin/tabs/attendance_tab.dart');

    expect(source, contains('_buildAttendanceCommandHeader'));
    expect(source, contains('_buildSelectedAttendanceDetailPanel'));
    expect(source, contains('ToastMetricStrip('));
    expect(source, contains('attendance_payroll_secondary_detail'));
    expect(source, contains("Key('attendance_secondary_signals_detail')"));
    expect(source, contains('initiallyExpanded: false'));
    expect(source, isNot(contains('PosPageHeader(')));
    expect(source, isNot(contains('PosToolbar(')));
    expect(source, isNot(contains('PosStatCard(')));
    expect(source, isNot(contains('PosActionCard(')));
  });
}
