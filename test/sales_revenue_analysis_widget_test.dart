import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/widgets/sales_revenue_analysis_dashboard.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

ReportSummary _summary() {
  return ReportSummary(
    dineInRevenue: 9200000,
    deliveryRevenue: 1800000,
    serviceTotal: 0,
    totalRevenue: 11000000,
    totalOrders: 82,
    completedOrders: 82,
    paidOrders: 82,
    openOrders: 0,
    dailyBreakdown: [
      for (var day = 8; day <= 14; day++)
        DailyRevenue(
          date: DateTime(2026, 8, day),
          dineIn: day * 100000,
          delivery: day * 20000,
          total: day * 120000,
          teamCount: day - 1,
        ),
    ],
    hourlyBreakdown: [
      for (var hour = 8; hour <= 22; hour++)
        HourlyRevenue(
          hour: hour,
          amount: hour >= 17 && hour <= 20 ? hour * 150000 : hour * 50000,
        ),
    ],
  );
}

Widget _app({
  required ValueChanged<int> onQuickRangeSelected,
  TextScaler? textScaler,
}) {
  return MaterialApp(
    locale: const Locale('ko'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: textScaler == null
        ? null
        : (context, child) => MediaQuery(
            data: MediaQuery.of(context).copyWith(textScaler: textScaler),
            child: child!,
          ),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SalesRevenueAnalysisDashboard(
          summary: _summary(),
          startDate: DateTime(2026, 8, 8),
          endDate: DateTime(2026, 8, 14),
          isLoading: false,
          error: null,
          onQuickRangeSelected: onQuickRangeSelected,
          onStartDatePressed: () {},
          onEndDatePressed: () {},
          onApplyCustomRange: () {},
          onRetry: () {},
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in const [Size(390, 844), Size(1200, 900)]) {
    testWidgets('sales analysis renders responsive charts at $size', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app(onQuickRangeSelected: (_) {}));
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('sales_daily_line_chart')), findsOneWidget);
      expect(
        find.byKey(const Key('sales_daily_revenue_chart')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('sales_daily_team_chart')), findsOneWidget);
      expect(
        find.byKey(const Key('sales_daily_average_chart')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('sales_hourly_bar_chart')), findsOneWidget);
      expect(find.text('매출 팀수'), findsOneWidget);
      expect(find.text('테이블 평균 단가'), findsOneWidget);
      final hourlyChart = tester.widget<BarChart>(find.byType(BarChart));
      expect(
        hourlyChart.data.barGroups.map((group) => group.x),
        orderedEquals([for (var hour = 11; hour <= 22; hour++) hour]),
      );
      expect(find.byKey(const Key('sales_daily_trend_badge')), findsOneWidget);
      expect(
        find.byKey(const Key('sales_revenue_analysis_filters')),
        findsOneWidget,
      );
      final filter = tester.getRect(
        find.byKey(const Key('sales_revenue_analysis_filters')),
      );
      final dailyPanel = tester.getRect(
        find.byKey(const Key('sales_daily_line_panel')),
      );
      expect(filter.bottom, lessThan(dailyPanel.top));
      if (size.width < 900) {
        final hourlyPanel = tester.getRect(
          find.byKey(const Key('sales_hourly_bar_panel')),
        );
        expect(hourlyPanel.top, greaterThan(dailyPanel.bottom));
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('quick period controls expose 1 week, 2 weeks, and one month', (
    tester,
  ) async {
    var selectedDays = 0;
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(onQuickRangeSelected: (days) => selectedDays = days),
    );
    await tester.pumpAndSettle();

    final twoWeeks = find.byKey(const Key('sales_range_14_days'));
    await tester.ensureVisible(twoWeeks);
    await tester.pumpAndSettle();
    await tester.tap(twoWeeks);
    await tester.pump();

    expect(selectedDays, 14);
    expect(find.text('1주'), findsOneWidget);
    expect(find.text('2주'), findsOneWidget);
    expect(find.text('한 달'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone period and charts remain readable at 200 percent text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(onQuickRangeSelected: (_) {}, textScaler: TextScaler.linear(2)),
    );
    await tester.pumpAndSettle();

    final filter = tester.getRect(
      find.byKey(const Key('sales_revenue_analysis_filters')),
    );
    final dailyPanel = tester.getRect(
      find.byKey(const Key('sales_daily_line_panel')),
    );
    expect(filter.bottom, lessThan(dailyPanel.top));
    expect(find.byKey(const Key('sales_hourly_bar_panel')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  test('daily table average uses dine-in revenue per team', () {
    final firstDay = _summary().dailyBreakdown.first;

    expect(firstDay.teamCount, 7);
    expect(firstDay.averageTableAmount, closeTo(800000 / 7, 0.001));
  });

  test('daily metrics use independent truthful units', () {
    final rows = _summary().dailyBreakdown;

    expect(
      rows.map((row) => row.teamCount),
      orderedEquals([7, 8, 9, 10, 11, 12, 13]),
    );
    expect(rows.first.averageTableAmount, isNot(rows.first.total));
  });
}
