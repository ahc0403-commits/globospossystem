import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('qc admin surface stays exception-queue first', () {
    final source = readRepoFile('lib/features/admin/tabs/qc_tab.dart');

    expect(source, contains('_buildQcExceptionHeader'));
    expect(source, contains('_buildQcWorkflowControls'));
    expect(source, contains('ToastMetricStrip('));
    expect(source, contains("const [\n      'Follow-ups'"));
    expect(source, contains("Key('qc_analytics_secondary_detail')"));
    expect(source, contains('initiallyExpanded: false'));
    expect(source, contains('qcFollowupProvider'));
    expect(source, contains('qcCheckProvider'));
    expect(source, contains('qcTemplateProvider'));
    expect(source, isNot(contains('PosPageHeader(')));
    expect(source, isNot(contains('PosToolbar(')));
    expect(source, isNot(contains('PosStatCard(')));
  });

  test('qc weekly board gives the lower table usable scroll space', () {
    final source = readRepoFile('lib/features/admin/tabs/qc_tab.dart');

    expect(source, contains('const _qcWeeklyBoardPageMinHeight = 940.0'));
    expect(
      source,
      contains(
        'minHeight: _selectedSurfaceIndex == 1\n'
        '            ? _qcWeeklyBoardPageMinHeight\n'
        '            : _qcDefaultPageMinHeight',
      ),
    );
    expect(source, contains("Key('qc_weekly_board_table')"));
    expect(source, contains('const _qcWeeklyBoardScrollPadding'));
    expect(source, contains('const _qcWeeklyBoardScrollPhysics'));
    expect(
      RegExp(r'physics: _qcWeeklyBoardScrollPhysics').allMatches(source).length,
      greaterThanOrEqualTo(3),
    );
    expect(
      RegExp(r'padding: _qcWeeklyBoardScrollPadding').allMatches(source).length,
      greaterThanOrEqualTo(2),
    );
  });
}
