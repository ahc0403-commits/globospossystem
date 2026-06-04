import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('einvoice admin surface stays exception-queue first', () {
    final source = readRepoFile('lib/features/admin/tabs/einvoice_tab.dart');

    expect(source, contains('_buildEinvoiceExceptionHeader'));
    expect(source, contains('_buildEinvoiceQueueControls'));
    expect(source, contains('ToastMetricStrip('));
    expect(source, contains("Key('einvoice_job_secondary_detail')"));
    expect(source, contains('initiallyExpanded: false'));
    expect(source, contains(".from('einvoice_jobs')"));
    expect(source, contains('admin_retry_einvoice_job'));
    expect(source, contains('admin_mark_resolved_einvoice_job'));
    expect(source, isNot(contains('PosPageHeader(')));
    expect(source, isNot(contains('PosToolbar(')));
    expect(source, isNot(contains('PosStatCard(')));
  });

  test(
    'einvoice compact stack delegates queue and detail scrolling to parent',
    () {
      final source = readRepoFile('lib/features/admin/tabs/einvoice_tab.dart');

      expect(source, contains('viewport.maxWidth < 1120'));
      expect(source, contains('ToastResponsiveScrollBody('));
      expect(source, contains('scrollable: false'));
      expect(source, contains('scrollable: true'));
      expect(source, contains('shrinkWrap: !scrollable'));
      expect(source, contains('NeverScrollableScrollPhysics'));
      expect(source, contains('required bool scrollable'));
      expect(
        source,
        isNot(contains('SizedBox(height: 420, child: queuePane)')),
      );
    },
  );
}
