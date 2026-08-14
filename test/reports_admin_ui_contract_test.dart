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
    expect(source, contains("Key('reports_actionable_issues')"));
    expect(source, contains("Key('reports_missing_proof_issue')"));
    expect(source, contains("Key('reports_einvoice_issue')"));
    expect(source, contains("Key('reports_date_filter_status')"));
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
      expect(
        source.indexOf('ReportAnalysisLaunchers('),
        lessThan(source.indexOf('compactHeader,')),
      );
      expect(source, contains("Key('paperless_operations_launcher')"));
      expect(source, contains("Key('menu_sales_analytics_launcher')"));
      expect(source, contains("Key('sales_revenue_analytics_launcher')"));
      expect(source, contains('PaperlessOperationsAnalyticsScreen('));
      expect(source, contains('MenuSalesAnalyticsScreen('));
      expect(source, contains('SalesRevenueAnalyticsScreen('));
      expect(source, isNot(contains('MenuSalesAnalyticsPanel(')));
      expect(source, isNot(contains('PaperlessOperationsDashboard(')));
      expect(source, contains('operationalReportHeight'));
      expect(source, contains('520.0 + 12.0 + 320.0 + 12.0 + 240.0 + 260.0'));
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
    expect(screens, contains("Key('sales_revenue_analytics_screen')"));
    expect(screens, contains('PaperlessOperationsDashboard('));
    expect(screens, contains('MenuSalesAnalyticsPanel('));
    expect(screens, contains('SalesRevenueAnalysisDashboard('));
    expect(screens, contains('ToastResponsiveScrollBody('));
  });

  test(
    'sales revenue analysis includes daily, hourly, and period controls',
    () {
      final dashboard = readRepoFile(
        'lib/features/admin/widgets/sales_revenue_analysis_dashboard.dart',
      );

      expect(dashboard, contains("Key('sales_daily_line_chart')"));
      expect(dashboard, contains("Key('sales_daily_team_chart')"));
      expect(dashboard, contains("Key('sales_daily_average_chart')"));
      expect(dashboard, contains('LineChart('));
      expect(dashboard, contains("Key('sales_hourly_bar_chart')"));
      expect(dashboard, contains('BarChart('));
      expect(dashboard, contains("Key('sales_range_7_days')"));
      expect(dashboard, contains("Key('sales_range_14_days')"));
      expect(dashboard, contains("Key('sales_range_30_days')"));
      expect(dashboard, contains("Key('sales_analysis_apply_range')"));
    },
  );
}
