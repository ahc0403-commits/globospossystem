import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/widgets/sales_revenue_analysis_dashboard.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

ReportSummary _summary({List<DailyRevenue>? dailyBreakdown}) {
  return ReportSummary(
    dineInRevenue: 9200000,
    deliveryRevenue: 1800000,
    serviceTotal: 0,
    totalRevenue: 11000000,
    totalOrders: 82,
    completedOrders: 82,
    paidOrders: 82,
    openOrders: 0,
    dailyBreakdown:
        dailyBreakdown ??
        [
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
  ReportSummary? summary,
  DateTime? startDate,
  DateTime? endDate,
  List<DailyRevenue>? priorDailyRevenue = const [],
  DateTime? appliedStartDate,
  DateTime? appliedEndDate,
  bool trendLoadFailed = false,
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
          summary: summary ?? _summary(),
          priorDailyRevenue: priorDailyRevenue,
          appliedStartDate: appliedStartDate,
          appliedEndDate: appliedEndDate,
          trendLoadFailed: trendLoadFailed,
          startDate: startDate ?? DateTime(2026, 8, 8),
          endDate: endDate ?? DateTime(2026, 8, 14),
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
        find.byKey(const Key('sales_revenue_trend_legend')),
        findsOneWidget,
      );
      expect(find.text('7일 이동평균'), findsOneWidget);
      final revenueChart = tester.widget<LineChart>(
        find.descendant(
          of: find.byKey(const Key('sales_daily_line_chart')),
          matching: find.byType(LineChart),
        ),
      );
      expect(revenueChart.data.lineBarsData, hasLength(2));
      expect(revenueChart.data.lineBarsData.last.dashArray, [8, 5]);
      expect(revenueChart.data.lineBarsData.last.spots, hasLength(7));
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

  testWidgets('two-week range uses fourteen-day moving average', (
    tester,
  ) async {
    final yesterday = DateUtils.dateOnly(
      DateTime.now().subtract(const Duration(days: 1)),
    );
    final first = yesterday.subtract(const Duration(days: 13));
    final rows = [
      for (var index = 0; index < 14; index++)
        DailyRevenue(
          date: first.add(Duration(days: index)),
          dineIn: (index + 1) * 100000,
          delivery: 0,
          total: (index + 1) * 100000,
          teamCount: index + 1,
        ),
    ];
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        onQuickRangeSelected: (_) {},
        summary: _summary(dailyBreakdown: rows),
        startDate: first,
        endDate: yesterday,
      ),
    );
    await tester.pumpAndSettle();

    final chart = tester.widget<LineChart>(
      find.descendant(
        of: find.byKey(const Key('sales_daily_line_chart')),
        matching: find.byType(LineChart),
      ),
    );
    expect(find.text('14일 이동평균'), findsOneWidget);
    expect(chart.data.lineBarsData.last.spots, hasLength(14));
    expect(tester.takeException(), isNull);
  });

  testWidgets('zero revenue for today is excluded from moving average', (
    tester,
  ) async {
    final today = DateUtils.dateOnly(toHoChiMinhBusinessTime(DateTime.now()));
    final first = today.subtract(const Duration(days: 6));
    final rows = [
      for (var index = 0; index < 7; index++)
        DailyRevenue(
          date: first.add(Duration(days: index)),
          dineIn: index == 6 ? 0 : (index + 1) * 100000,
          delivery: 0,
          total: index == 6 ? 0 : (index + 1) * 100000,
          teamCount: index == 6 ? 0 : index + 1,
        ),
    ];
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        onQuickRangeSelected: (_) {},
        summary: _summary(dailyBreakdown: rows),
        startDate: first,
        endDate: today,
      ),
    );
    await tester.pumpAndSettle();

    final chart = tester.widget<LineChart>(
      find.descendant(
        of: find.byKey(const Key('sales_daily_line_chart')),
        matching: find.byType(LineChart),
      ),
    );
    final trend = chart.data.lineBarsData.last;
    expect(trend.spots, hasLength(6));
    expect(trend.spots.last.x, 5);
    expect(trend.spots.last.y, closeTo(300000, 0.001));
    expect(tester.takeException(), isNull);
  });

  test('daily table average uses dine-in revenue per team', () {
    final firstDay = _summary().dailyBreakdown.first;

    expect(firstDay.teamCount, 7);
    expect(firstDay.averageTableAmount, closeTo(800000 / 7, 0.001));
  });

  for (final days in [1, 7, 10, 14, 30, 45]) {
    testWidgets(
      '$days-day selection calculates the matching average from the first visible day',
      (tester) async {
        final first = DateTime(2025, 12, 1);
        final all = [
          for (var i = 0; i < days * 2 - 1; i++)
            DailyRevenue(
              date: first.add(Duration(days: i)),
              dineIn: (i + 1) * 100000,
              delivery: 0,
              total: (i + 1) * 100000,
            ),
        ];
        final visible = all.sublist(days - 1);
        await tester.binding.setSurfaceSize(const Size(1200, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          _app(
            onQuickRangeSelected: (_) {},
            summary: _summary(dailyBreakdown: visible),
            startDate: visible.first.date,
            endDate: visible.last.date,
            priorDailyRevenue: all.take(days - 1).toList(),
          ),
        );
        await tester.pumpAndSettle();
        final chart = tester.widget<LineChart>(
          find.descendant(
            of: find.byKey(const Key('sales_daily_line_chart')),
            matching: find.byType(LineChart),
          ),
        );
        final trend = chart.data.lineBarsData.last;
        expect(find.text('$days일 이동평균'), findsOneWidget);
        expect(trend.spots, hasLength(days));
        expect(trend.spots.first.x, 0);
        expect(trend.spots.first.y, closeTo((days + 1) / 2 * 100000, 0.001));
        expect(trend.spots.last.x, days - 1);
        expect(trend.spots.last.y, closeTo((3 * days - 1) / 2 * 100000, 0.001));
        expect(chart.data.lineBarsData.first.spots, hasLength(days));
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'draft dates do not relabel or expand the applied revenue series',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          onQuickRangeSelected: (_) {},
          startDate: DateTime(2026, 7, 16),
          endDate: DateTime(2026, 8, 14),
          appliedStartDate: DateTime(2026, 8, 8),
          appliedEndDate: DateTime(2026, 8, 14),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('7일 이동평균'), findsOneWidget);
      expect(find.text('30일 이동평균'), findsNothing);
      final chart = tester.widget<LineChart>(
        find.descendant(
          of: find.byKey(const Key('sales_daily_line_chart')),
          matching: find.byType(LineChart),
        ),
      );
      expect(chart.data.lineBarsData.first.spots, hasLength(7));
    },
  );

  testWidgets(
    'failed history keeps revenue and never invents preceding zeroes',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          onQuickRangeSelected: (_) {},
          priorDailyRevenue: null,
          trendLoadFailed: true,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sales_average_status')), findsOneWidget);
      final chart = tester.widget<LineChart>(
        find.descendant(
          of: find.byKey(const Key('sales_daily_line_chart')),
          matching: find.byType(LineChart),
        ),
      );
      expect(chart.data.lineBarsData.first.spots, hasLength(7));
      expect(chart.data.lineBarsData.last.spots, hasLength(1));
      expect(chart.data.lineBarsData.last.spots.single.x, 6);
    },
  );

  test('daily metrics use independent truthful units', () {
    final rows = _summary().dailyBreakdown;

    expect(
      rows.map((row) => row.teamCount),
      orderedEquals([7, 8, 9, 10, 11, 12, 13]),
    );
    expect(rows.first.averageTableAmount, isNot(rows.first.total));
  });

  testWidgets(
    'a high preceding average stays inside the chart after sales fall',
    (tester) async {
      final start = DateTime(2026, 1, 1);
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          onQuickRangeSelected: (_) {},
          startDate: start,
          endDate: start.add(const Duration(days: 29)),
          summary: _summary(
            dailyBreakdown: [
              for (var i = 0; i < 30; i++)
                DailyRevenue(
                  date: start.add(Duration(days: i)),
                  dineIn: 10000,
                  delivery: 0,
                  total: 10000,
                ),
            ],
          ),
          priorDailyRevenue: [
            for (var i = 1; i < 30; i++)
              DailyRevenue(
                date: start.subtract(Duration(days: i)),
                dineIn: 1000000,
                delivery: 0,
                total: 1000000,
              ),
          ],
        ),
      );
      await tester.pumpAndSettle();
      final chart = tester.widget<LineChart>(
        find.descendant(
          of: find.byKey(const Key('sales_daily_line_chart')),
          matching: find.byType(LineChart),
        ),
      );
      final firstAverage = chart.data.lineBarsData.last.spots.first.y;
      expect(firstAverage, closeTo(29010000 / 30, 0.001));
      expect(chart.data.maxY, greaterThan(firstAverage));
      expect(chart.data.lineBarsData.first.spots.first.y, 10000);
    },
  );
}
