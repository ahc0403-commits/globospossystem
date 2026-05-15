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
}
