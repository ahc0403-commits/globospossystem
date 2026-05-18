import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('reports admin surface keeps period analysis as the primary job', () {
    final source = readRepoFile('lib/features/admin/tabs/reports_tab.dart');

    expect(source, contains('_buildReportsCommandHeader'));
    expect(source, contains('ToastMetricStrip('));
    expect(source, contains("Key('reports_operational_signals_detail')"));
    expect(source, contains('initiallyExpanded: false'));
    expect(source, isNot(contains('PosPageHeader(')));
    expect(source, isNot(contains('PosToolbar(')));
    expect(source, isNot(contains('PosStatCard(')));
    expect(source, isNot(contains('_ReportsMetricCard')));
  });
}
