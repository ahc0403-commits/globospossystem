import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('reports admin surface keeps period analysis as the primary job', () {
    final source = readRepoFile('lib/features/admin/tabs/reports_tab.dart');

    expect(source, contains('_buildReportsCommandHeader'));
    expect(source, contains('ToastMetricStrip('));
    expect(source, contains('label: l10n.reportsPaidOrders'));
    expect(source, contains('summary.paidOrders'));
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
      expect(source, contains('maxColumns: 4'));
      expect(source, contains('520.0 + 12.0 + 240.0 + 260.0'));
      expect(source, contains('height: 240'));
      expect(source, contains('reportConstraints.maxWidth < 1080'));
      expect(source, contains('compactSecondaryHeight: 520'));
      expect(source, contains('keyboardDismissBehavior:'));
      expect(source, contains('ScrollViewKeyboardDismissBehavior.onDrag'));
    },
  );

  test('daily sales keeps bank transfer separate from card', () {
    final provider = readRepoFile('lib/features/report/report_provider.dart');
    final reports = readRepoFile('lib/features/admin/tabs/reports_tab.dart');

    expect(provider, contains('bankTransferAmount'));
    expect(provider, contains('bankTransferTotal'));
    expect(provider, contains('amount_portion'));
    expect(provider, contains('paymentVariance'));
    expect(provider, isNot(contains("'banktransfer' => 'CARD'")));
    expect(reports, contains('l10n.cashierBankTransferMethod'));
    expect(reports, contains('l10n.reportsPaymentVariance'));
    expect(reports, contains('row.bankTransferAmount'));
    expect(reports, contains('data.bankTransferTotal'));
  });
}
