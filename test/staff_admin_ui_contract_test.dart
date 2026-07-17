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
    expect(source, contains('this.initiallyExpanded = false'));
    expect(source, isNot(contains('PosPageHeader(')));
    expect(source, isNot(contains('PosToolbar(')));
    expect(source, isNot(contains('PosStatCard(')));
    expect(source, isNot(contains('_StaffFilterChip')));
    expect(source, isNot(contains('staffExcelDownload')));
  });

  test('staff compact stack keeps the directory list on the parent scroll', () {
    final source = readRepoFile('lib/features/admin/tabs/staff_tab.dart');

    expect(source, contains('final compact = viewport.maxWidth < 1120'));
    expect(source, contains('header(compact: true)'));
    expect(source, contains('compact: true'));
    expect(source, contains('scrollDirection: Axis.horizontal'));
    expect(source, contains('ToastResponsiveScrollBody('));
    expect(source, contains('scrollable: false'));
    expect(source, contains('bool scrollable = true'));
    expect(source, contains('shrinkWrap: !scrollable'));
    expect(source, contains('NeverScrollableScrollPhysics'));
    expect(source, isNot(contains('SizedBox(height: 420, child: listPane)')));
  });

  test('staff compact detail surfaces quick actions before dense history', () {
    final source = readRepoFile('lib/features/admin/tabs/staff_tab.dart');

    expect(source, contains('initiallyExpanded: compact'));
    expect(source, contains('showAttendancePreview: !compact'));
    expect(source, contains('this.initiallyExpanded = false'));
    expect(source, contains('this.showAttendancePreview = true'));

    final compactDetailIndex = source.indexOf('compact: true,');
    final compactListIndex = source.indexOf('scrollable: false');
    expect(compactDetailIndex, isNonNegative);
    expect(compactListIndex, isNonNegative);
    expect(compactDetailIndex, lessThan(compactListIndex));
  });
}
