import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('reports workspace exposes a read-only operational attention layer', () {
    final reportsTab = readRepoFile('lib/features/admin/tabs/reports_tab.dart');
    final reportProvider = readRepoFile(
      'lib/features/report/report_provider.dart',
    );

    expect(
      reportsTab,
      contains("import '../../../core/i18n/locale_extensions.dart';"),
    );
    expect(reportsTab, contains('context.l10n'));
    expect(reportsTab, contains('l10n.reportsOperationalAttentionTitle'));
    expect(reportsTab, contains('l10n.reportsOperationalAttentionSubtitle'));
    expect(reportsTab, contains('l10n.reportsOperationalMissingProof'));
    expect(reportsTab, contains('l10n.reportsOperationalFailedEInvoice'));
    expect(reportsTab, contains('l10n.reportsOperationalProofCompletion'));
    expect(
      reportsTab,
      contains('l10n.reportsOperationalWt08ComparableReported'),
    );
    expect(reportsTab, contains('l10n.reportsOperationalFollowUpNow'));
    expect(reportsTab, contains('l10n.reportsOperationalHealthySignals'));
    expect(reportsTab, contains('l10n.reportsOperationalWt08Readiness'));
    expect(reportsTab, contains('l10n.reportsOperationalFollowUpFocus'));
    expect(reportsTab, contains('l10n.reportsOperationalHealthyBaseline'));
    expect(reportsTab, contains('l10n.reportsOperationalBoundary'));
    expect(reportsTab, contains('_signalCard('));
    expect(reportsTab, contains('_statusStrip('));
    expect(reportsTab, contains('_statusStripBadge('));
    expect(reportsTab, contains('summary.totalOrders == 0'));

    expect(reportProvider, contains('missingProofPhotosCount'));
    expect(reportProvider, contains('failedEinvoiceJobsCount'));
    expect(reportProvider, contains('wetaxReportedCount'));
    expect(reportProvider, contains('wt08ComparablePosCount'));
    expect(reportProvider, contains('proofCompletePercent'));

    expect(reportsTab, isNot(contains('retryEinvoice')));
    expect(reportsTab, isNot(contains("path: '/reports/operations'")));
    expect(reportsTab, isNot(contains('Navigator.push(')));
    expect(
      reportsTab,
      isNot(contains('run_inventory_purchase_recommendation')),
    );
  });
}
