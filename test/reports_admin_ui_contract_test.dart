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
      expect(source, contains('DailyClosingLauncher(storeId: storeId)'));
      expect(source, contains("Key('daily_closing_open_screen')"));
      expect(source, contains('DailyClosingScreen(storeId: storeId)'));
      expect(source, contains('DailyClosingPresentation.cards'));
      expect(source, contains('compactReportHeight'));
      expect(source, contains('maxColumns: 4'));
      expect(source, contains('ReportAnalysisLaunchers('));
      expect(source, contains("Key('paperless_operations_launcher')"));
      expect(source, contains("Key('menu_sales_analytics_launcher')"));
      expect(source, contains('PaperlessOperationsAnalyticsScreen('));
      expect(source, contains('MenuSalesAnalyticsScreen('));
      expect(source, isNot(contains('MenuSalesAnalyticsPanel(')));
      expect(source, isNot(contains('PaperlessOperationsDashboard(')));
      expect(source, contains('operationalReportHeight'));
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

  test('report analyses render on dedicated screens', () {
    final screens = readRepoFile(
      'lib/features/admin/report_analysis_screens.dart',
    );

    expect(screens, contains("Key('paperless_operations_analytics_screen')"));
    expect(screens, contains("Key('menu_sales_analytics_screen')"));
    expect(screens, contains('PaperlessOperationsDashboard('));
    expect(screens, contains('MenuSalesAnalyticsPanel('));
    expect(screens, contains('ToastResponsiveScrollBody('));
  });
}
