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

  test(
    'reports compact analysis uses a parent scroll instead of overflowing',
    () {
      final source = readRepoFile('lib/features/admin/tabs/reports_tab.dart');

      expect(source, contains("Key('reports_compact_scroll')"));
      expect(source, contains('compactReportHeight'));
      expect(source, contains('maxColumns: 5'));
      expect(source, contains('520.0 + 12.0 + 240.0'));
      expect(source, contains('height: 240'));
      expect(source, contains('reportConstraints.maxWidth < 1080'));
      expect(source, contains('compactSecondaryHeight: 520'));
      expect(source, contains('keyboardDismissBehavior:'));
      expect(source, contains('ScrollViewKeyboardDismissBehavior.onDrag'));
    },
  );
}
