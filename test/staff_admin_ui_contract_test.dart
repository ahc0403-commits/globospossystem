import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('staff admin surface stays compact and directory-first', () {
    final source = readRepoFile('lib/features/admin/tabs/staff_tab.dart');

    expect(source, contains('_buildStaffCommandHeader'));
    expect(source, contains('ToastMetricStrip('));
    expect(source, contains('ToastSplitPane('));
    expect(source, contains("Key('staff_detail_secondary_detail')"));
    expect(source, contains('initiallyExpanded: false'));
    expect(source, isNot(contains('PosPageHeader(')));
    expect(source, isNot(contains('PosToolbar(')));
    expect(source, isNot(contains('PosStatCard(')));
    expect(source, isNot(contains('_StaffFilterChip')));
    expect(source, isNot(contains('staffExcelDownload')));
  });
}
