import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('menu admin surface stays compact and task-first', () {
    final source = readRepoFile('lib/features/admin/tabs/menu_tab.dart');

    expect(source, contains('_buildMenuCommandHeader'));
    expect(source, contains('ToastMetricStrip('));
    expect(source, contains('ToastSplitPane('));
    expect(source, contains("Key('menu_audit_secondary_detail')"));
    expect(source, contains('initiallyExpanded: false'));
    expect(source, isNot(contains('PosStatCard(')));
    expect(source, isNot(contains('PosPageHeader(')));
    expect(source, isNot(contains("_MenuSurfaceTab(label: '옵션')")));
    expect(source, isNot(contains("_MenuSurfaceTab(label: '메뉴 그룹')")));
  });
}
