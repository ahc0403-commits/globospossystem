import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('reports workspace exposes actionable MISA and proof issue details', () {
    final reportsTab = readRepoFile('lib/features/admin/tabs/reports_tab.dart');
    final reportProvider = readRepoFile(
      'lib/features/report/report_provider.dart',
    );

    expect(
      reportsTab,
      contains("import '../../../core/i18n/locale_extensions.dart';"),
    );
    expect(reportsTab, contains('context.l10n'));
    expect(reportsTab, contains("Key('reports_actionable_issues')"));
    expect(reportsTab, contains("Key('reports_missing_proof_issue')"));
    expect(reportsTab, contains("Key('reports_einvoice_issue')"));
    expect(reportsTab, contains('class _ReportIssueDetailsView'));
    expect(reportsTab, contains("Key('reports_issue_detail_list')"));
    expect(reportsTab, contains("context.push('/payments/"));
    expect(reportsTab, contains("Key('reports_date_filter_status')"));
    expect(reportsTab, contains("Key('daily_closing_cash_dialog')"));

    expect(reportProvider, contains('missingProofPhotosCount'));
    expect(reportProvider, contains('failedEinvoiceJobsCount'));
    expect(reportProvider, contains('proofCompletePercent'));
    expect(reportProvider, contains(".from('meinvoice_jobs')"));
    expect(reportProvider, contains('collectMissingProofIssues'));
    expect(reportProvider, contains('collectEinvoiceReviewIssues'));

    expect(reportsTab, isNot(contains('WT08')));
    expect(reportsTab, isNot(contains('WeTax')));
    expect(reportProvider, isNot(contains(".from('einvoice_jobs')")));
    expect(reportProvider, isNot(contains('wetax_daily_close')));
  });
}
