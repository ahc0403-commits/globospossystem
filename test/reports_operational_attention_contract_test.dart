import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('reports workspace exposes a read-only operational attention layer', () {
    final reportsTab = readRepoFile('lib/features/admin/tabs/reports_tab.dart');
    final reportProvider = readRepoFile(
      'lib/features/report/report_provider.dart',
    );

    expect(reportsTab, contains('Operational Attention'));
    expect(
      reportsTab,
      contains('Read-only readiness layer built from tracked report summary fields.'),
    );
    expect(reportsTab, contains('Missing proof'));
    expect(reportsTab, contains('Failed e-invoice'));
    expect(reportsTab, contains('Proof completion'));
    expect(reportsTab, contains('WT08-comparable POS orders reported'));
    expect(reportsTab, contains('Follow-up now'));
    expect(reportsTab, contains('Healthy signals'));
    expect(reportsTab, contains('WT08 readiness'));
    expect(reportsTab, contains('Follow-up focus'));
    expect(reportsTab, contains('Healthy baseline'));
    expect(reportsTab, contains('Boundary'));

    expect(reportProvider, contains('missingProofPhotosCount'));
    expect(reportProvider, contains('failedEinvoiceJobsCount'));
    expect(reportProvider, contains('wetaxReportedCount'));
    expect(reportProvider, contains('wt08ComparablePosCount'));
    expect(reportProvider, contains('proofCompletePercent'));

    expect(reportsTab, isNot(contains('retryEinvoice')));
    expect(reportsTab, isNot(contains("path: '/reports/operations'")));
    expect(reportsTab, isNot(contains('Navigator.push(')));
    expect(reportsTab, isNot(contains('run_inventory_purchase_recommendation')));
  });
}
