import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/ui/app_fonts.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../core/ui/toast/toast.dart';
import '../../report/report_provider.dart';

class SalesRevenueAnalysisDashboard extends StatelessWidget {
  const SalesRevenueAnalysisDashboard({
    super.key,
    required this.summary,
    required this.startDate,
    required this.endDate,
    required this.isLoading,
    required this.error,
    required this.onQuickRangeSelected,
    required this.onStartDatePressed,
    required this.onEndDatePressed,
    required this.onApplyCustomRange,
    required this.onRetry,
  });

  final ReportSummary? summary;
  final DateTime startDate;
  final DateTime endDate;
  final bool isLoading;
  final String? error;
  final ValueChanged<int> onQuickRangeSelected;
  final VoidCallback onStartDatePressed;
  final VoidCallback onEndDatePressed;
  final VoidCallback onApplyCustomRange;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final copy = _SalesAnalysisCopy.of(context);
    final currency = NumberFormat('#,###', 'vi_VN');
    final dateFormat = DateFormat('dd/MM/yyyy');
    final normalizedStart = DateTime(
      startDate.year,
      startDate.month,
      startDate.day,
    );
    final normalizedEnd = DateTime(endDate.year, endDate.month, endDate.day);
    final selectedDays = normalizedEnd.difference(normalizedStart).inDays + 1;

    return Column(
      key: const Key('sales_revenue_analysis_dashboard'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildContent(context, copy, currency),
        const SizedBox(height: 12),
        PosActionCard(
          key: const Key('sales_revenue_analysis_filters'),
          title: copy.periodTitle,
          subtitle: copy.periodSubtitle,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  _QuickRangeButton(
                    key: const Key('sales_range_7_days'),
                    label: copy.oneWeek,
                    selected: selectedDays == 7,
                    onPressed: () => onQuickRangeSelected(7),
                  ),
                  _QuickRangeButton(
                    key: const Key('sales_range_14_days'),
                    label: copy.twoWeeks,
                    selected: selectedDays == 14,
                    onPressed: () => onQuickRangeSelected(14),
                  ),
                  _QuickRangeButton(
                    key: const Key('sales_range_30_days'),
                    label: copy.oneMonth,
                    selected: selectedDays == 30,
                    onPressed: () => onQuickRangeSelected(30),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  OutlinedButton.icon(
                    key: const Key('sales_analysis_start_date'),
                    onPressed: onStartDatePressed,
                    icon: const Icon(Icons.event_outlined, size: 17),
                    label: Text('${copy.from} ${dateFormat.format(startDate)}'),
                  ),
                  OutlinedButton.icon(
                    key: const Key('sales_analysis_end_date'),
                    onPressed: onEndDatePressed,
                    icon: const Icon(Icons.event_available_outlined, size: 17),
                    label: Text('${copy.to} ${dateFormat.format(endDate)}'),
                  ),
                  FilledButton.icon(
                    key: const Key('sales_analysis_apply_range'),
                    onPressed: onApplyCustomRange,
                    icon: const Icon(Icons.search_rounded, size: 17),
                    label: Text(copy.apply),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildContent(
    BuildContext context,
    _SalesAnalysisCopy copy,
    NumberFormat currency,
  ) {
    if (isLoading) {
      return SizedBox(
        height: 440,
        child: ToastOperationalLoadingState(label: copy.loading),
      );
    }

    if (error != null && summary == null) {
      return ToastWorkSurface(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            PosEmptyState(
              title: copy.unavailable,
              subtitle: error!,
              icon: Icons.error_outline_rounded,
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.center,
              child: PosPrimaryButton(
                label: copy.retry,
                icon: Icons.refresh_rounded,
                onPressed: onRetry,
              ),
            ),
          ],
        ),
      );
    }

    final data = summary;
    if (data == null ||
        (data.dailyBreakdown.isEmpty && data.hourlyBreakdown.isEmpty)) {
      return ToastWorkSurface(
        child: PosEmptyState(
          title: copy.noDataTitle,
          subtitle: copy.noDataSubtitle,
          icon: Icons.show_chart_outlined,
        ),
      );
    }

    final daily = _fillDailyRange(data.dailyBreakdown, startDate, endDate);
    final hourly = _fillHourlyRange(data.hourlyBreakdown);
    return LayoutBuilder(
      builder: (context, constraints) {
        final dailyPanel = PosDataPanel(
          key: const Key('sales_daily_line_panel'),
          title: copy.dailyTitle,
          subtitle: copy.dailySubtitle,
          trailing: _RevenueTrendBadge(rows: daily, currency: currency),
          child: _DailyRevenuePanelContent(rows: daily, currency: currency),
        );
        final hourlyPanel = PosDataPanel(
          key: const Key('sales_hourly_bar_panel'),
          title: copy.hourlyTitle,
          subtitle: copy.hourlySubtitle,
          child: _HourlyRevenueBarChart(rows: hourly, currency: currency),
        );

        if (constraints.maxWidth < 900) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(height: 400, child: dailyPanel),
              const SizedBox(height: 12),
              SizedBox(height: 400, child: hourlyPanel),
            ],
          );
        }
        return SizedBox(
          height: 430,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: dailyPanel),
              const SizedBox(width: 12),
              Expanded(child: hourlyPanel),
            ],
          ),
        );
      },
    );
  }
}

List<DailyRevenue> _fillDailyRange(
  List<DailyRevenue> rows,
  DateTime start,
  DateTime end,
) {
  final first = DateTime(start.year, start.month, start.day);
  final last = DateTime(end.year, end.month, end.day);
  final byDate = <String, DailyRevenue>{
    for (final row in rows) DateFormat('yyyy-MM-dd').format(row.date): row,
  };
  final result = <DailyRevenue>[];
  for (
    var day = first;
    !day.isAfter(last);
    day = day.add(const Duration(days: 1))
  ) {
    result.add(
      byDate[DateFormat('yyyy-MM-dd').format(day)] ??
          DailyRevenue(date: day, dineIn: 0, delivery: 0, total: 0),
    );
  }
  return result;
}

List<HourlyRevenue> _fillHourlyRange(List<HourlyRevenue> rows) {
  final byHour = <int, double>{for (final row in rows) row.hour: row.amount};
  return [
    for (var hour = 11; hour <= 22; hour++)
      HourlyRevenue(hour: hour, amount: byHour[hour] ?? 0),
  ];
}

class _RevenueTrendBadge extends StatelessWidget {
  const _RevenueTrendBadge({required this.rows, required this.currency});

  final List<DailyRevenue> rows;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final copy = _SalesAnalysisCopy.of(context);
    final first = rows.isEmpty ? 0.0 : rows.first.total;
    final last = rows.isEmpty ? 0.0 : rows.last.total;
    final delta = last - first;
    final increased = delta > 0;
    final decreased = delta < 0;
    final tone = increased
        ? PosColors.success
        : decreased
        ? PosColors.danger
        : PosColors.textSecondary;
    final icon = increased
        ? Icons.trending_up_rounded
        : decreased
        ? Icons.trending_down_rounded
        : Icons.trending_flat_rounded;
    final label = increased
        ? copy.increased
        : decreased
        ? copy.decreased
        : copy.unchanged;

    return Container(
      key: const Key('sales_daily_trend_badge'),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 16, color: tone),
          const SizedBox(width: 5),
          Text(
            '$label ${currency.format(delta.abs())} VND',
            style: AppFonts.system(
              color: tone,
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _DailyRevenueLineChart extends StatelessWidget {
  const _DailyRevenueLineChart({required this.rows, required this.currency});

  final List<DailyRevenue> rows;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final copy = _SalesAnalysisCopy.of(context);
    final maxAmount = rows.fold<double>(
      0,
      (max, row) => math.max(max, row.total),
    );
    final maxY = maxAmount <= 0 ? 1.0 : maxAmount * 1.2;
    final interval = maxY / 4;
    final labelStep = math.max(1, (rows.length / 5).ceil());

    return LayoutBuilder(
      builder: (context, constraints) {
        final chartWidth = math.max(
          constraints.maxWidth,
          rows.length * 32.0 + 54,
        );
        return ClipRect(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SizedBox(
              key: const Key('sales_daily_line_chart'),
              width: chartWidth,
              child: LineChart(
                LineChartData(
                  minX: -0.55,
                  maxX: math.max(1, rows.length - 1).toDouble() + 0.55,
                  minY: 0,
                  maxY: maxY,
                  gridData: FlGridData(
                    show: true,
                    drawVerticalLine: false,
                    horizontalInterval: interval,
                    getDrawingHorizontalLine: (_) =>
                        const FlLine(color: PosColors.border, strokeWidth: 1),
                  ),
                  borderData: FlBorderData(show: false),
                  titlesData: FlTitlesData(
                    topTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    rightTitles: const AxisTitles(
                      sideTitles: SideTitles(showTitles: false),
                    ),
                    leftTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 54,
                        interval: interval,
                        getTitlesWidget: (value, meta) {
                          if (value >= meta.max) return const SizedBox.shrink();
                          return SideTitleWidget(
                            axisSide: meta.axisSide,
                            space: 6,
                            child: Text(
                              _compactCurrency(value),
                              style: AppFonts.system(
                                color: PosColors.textSecondary,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 34,
                        getTitlesWidget: (value, meta) {
                          final index = value.toInt();
                          if (index < 0 ||
                              index >= rows.length ||
                              value != index.toDouble() ||
                              (index % labelStep != 0 &&
                                  index != rows.length - 1)) {
                            return const SizedBox.shrink();
                          }
                          return SideTitleWidget(
                            axisSide: meta.axisSide,
                            space: 8,
                            child: Text(
                              DateFormat('dd/MM').format(rows[index].date),
                              style: AppFonts.system(
                                color: PosColors.textSecondary,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                  ),
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      fitInsideHorizontally: true,
                      fitInsideVertically: true,
                      getTooltipItems: (spots) => spots.map((spot) {
                        final row = rows[spot.x.toInt()];
                        return LineTooltipItem(
                          '${DateFormat('dd/MM').format(row.date)}\n'
                          '${currency.format(spot.y)} VND\n'
                          '${copy.teamLabel} ${row.teamCount}\n'
                          '${copy.averageTableLabel} '
                          '${currency.format(row.averageTableAmount)} VND',
                          AppFonts.system(
                            color: Colors.white,
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        );
                      }).toList(),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: [
                        for (var index = 0; index < rows.length; index++)
                          FlSpot(index.toDouble(), rows[index].total),
                      ],
                      isCurved: rows.length > 2,
                      curveSmoothness: 0.25,
                      color: PosColors.accent,
                      barWidth: 3,
                      isStrokeCapRound: true,
                      dotData: FlDotData(show: rows.length <= 14),
                      belowBarData: BarAreaData(
                        show: true,
                        color: PosColors.accent.withValues(alpha: 0.1),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}

class _DailyRevenuePanelContent extends StatelessWidget {
  const _DailyRevenuePanelContent({required this.rows, required this.currency});

  final List<DailyRevenue> rows;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: _DailyRevenueLineChart(rows: rows, currency: currency),
        ),
        const SizedBox(height: 8),
        _DailyMetricsStrip(rows: rows),
      ],
    );
  }
}

class _DailyMetricsStrip extends StatelessWidget {
  const _DailyMetricsStrip({required this.rows});

  final List<DailyRevenue> rows;

  @override
  Widget build(BuildContext context) {
    final copy = _SalesAnalysisCopy.of(context);
    return Container(
      key: const Key('sales_daily_metrics_strip'),
      height: 66,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: PosColors.border)),
      ),
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.only(top: 9),
        itemCount: rows.length,
        separatorBuilder: (context, index) => const VerticalDivider(
          width: 8,
          thickness: 1,
          indent: 4,
          endIndent: 4,
          color: PosColors.border,
        ),
        itemBuilder: (context, index) {
          final row = rows[index];
          return SizedBox(
            key: Key(
              'sales_daily_metric_${DateFormat('yyyyMMdd').format(row.date)}',
            ),
            width: 64,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  DateFormat('dd/MM').format(row.date),
                  style: AppFonts.system(
                    color: PosColors.textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  copy.teamCount(row.teamCount),
                  style: AppFonts.system(
                    color: PosColors.textPrimary,
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                Text(
                  copy.averageTableShort(
                    _compactCurrency(row.averageTableAmount),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppFonts.system(
                    color: PosColors.textSecondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _HourlyRevenueBarChart extends StatelessWidget {
  const _HourlyRevenueBarChart({required this.rows, required this.currency});

  final List<HourlyRevenue> rows;
  final NumberFormat currency;

  @override
  Widget build(BuildContext context) {
    final maxAmount = rows.fold<double>(
      0,
      (max, row) => math.max(max, row.amount),
    );
    final maxY = maxAmount <= 0 ? 1.0 : maxAmount * 1.2;
    final interval = maxY / 4;

    return SizedBox(
      key: const Key('sales_hourly_bar_chart'),
      width: double.infinity,
      child: BarChart(
        BarChartData(
          minY: 0,
          maxY: maxY,
          alignment: BarChartAlignment.spaceAround,
          gridData: FlGridData(
            show: true,
            drawVerticalLine: false,
            horizontalInterval: interval,
            getDrawingHorizontalLine: (_) =>
                const FlLine(color: PosColors.border, strokeWidth: 1),
          ),
          borderData: FlBorderData(show: false),
          titlesData: FlTitlesData(
            topTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            rightTitles: const AxisTitles(
              sideTitles: SideTitles(showTitles: false),
            ),
            leftTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 54,
                interval: interval,
                getTitlesWidget: (value, meta) {
                  if (value >= meta.max) return const SizedBox.shrink();
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    space: 6,
                    child: Text(
                      _compactCurrency(value),
                      style: AppFonts.system(
                        color: PosColors.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                },
              ),
            ),
            bottomTitles: AxisTitles(
              sideTitles: SideTitles(
                showTitles: true,
                reservedSize: 30,
                interval: 1,
                getTitlesWidget: (value, meta) {
                  final hour = value.toInt();
                  if (rows.isEmpty ||
                      hour < rows.first.hour ||
                      hour > rows.last.hour) {
                    return const SizedBox.shrink();
                  }
                  return SideTitleWidget(
                    axisSide: meta.axisSide,
                    space: 7,
                    child: Text(
                      hour.toString().padLeft(2, '0'),
                      style: AppFonts.system(
                        color: PosColors.textSecondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          barTouchData: BarTouchData(
            touchTooltipData: BarTouchTooltipData(
              getTooltipItem: (group, groupIndex, rod, rodIndex) =>
                  BarTooltipItem(
                    '${group.x.toString().padLeft(2, '0')}:00\n'
                    '${currency.format(rod.toY)} VND',
                    AppFonts.system(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
            ),
          ),
          barGroups: [
            for (final row in rows)
              BarChartGroupData(
                x: row.hour,
                barRods: [
                  BarChartRodData(
                    toY: row.amount,
                    width: 17,
                    color: PosColors.accent,
                    borderRadius: const BorderRadius.vertical(
                      top: Radius.circular(5),
                    ),
                  ),
                ],
              ),
          ],
        ),
      ),
    );
  }
}

class _QuickRangeButton extends StatelessWidget {
  const _QuickRangeButton({
    super.key,
    required this.label,
    required this.selected,
    required this.onPressed,
  });

  final String label;
  final bool selected;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return selected
        ? FilledButton(onPressed: onPressed, child: Text(label))
        : OutlinedButton(onPressed: onPressed, child: Text(label));
  }
}

String _compactCurrency(double value) {
  final absolute = value.abs();
  if (absolute >= 1000000000) {
    return '${(value / 1000000000).toStringAsFixed(1)}B';
  }
  if (absolute >= 1000000) {
    return '${(value / 1000000).toStringAsFixed(1)}M';
  }
  if (absolute >= 1000) {
    return '${(value / 1000).toStringAsFixed(0)}K';
  }
  return value.toStringAsFixed(0);
}

class _SalesAnalysisCopy {
  const _SalesAnalysisCopy(this.code);

  final String code;

  static _SalesAnalysisCopy of(BuildContext context) =>
      _SalesAnalysisCopy(Localizations.localeOf(context).languageCode);

  String pick(String ko, String vi, String en) => switch (code) {
    'vi' => vi,
    'en' => en,
    _ => ko,
  };

  String get title => pick(
    '매출 추이 분석',
    'Phân tích xu hướng doanh thu',
    'Revenue trend analysis',
  );
  String get subtitle => pick(
    '일자별 매출 증감과 시간대별 집중 구간을 한 화면에서 확인합니다.',
    'Theo dõi biến động theo ngày và khung giờ doanh thu tập trung.',
    'Track daily changes and peak revenue hours in one view.',
  );
  String get dailyTitle =>
      pick('일자별 매출 추이', 'Xu hướng doanh thu theo ngày', 'Daily revenue trend');
  String get dailySubtitle => pick(
    '일자별 매출 증감과 팀수·테이블 평균 단가를 확인합니다.',
    'Xem doanh thu, số nhóm và giá trị trung bình mỗi bàn theo ngày.',
    'See daily revenue, teams, and average table value.',
  );
  String get teamLabel => pick('매출 팀수', 'Số nhóm', 'Sales teams');
  String get averageTableLabel =>
      pick('테이블 평균 단가', 'Giá trị TB mỗi bàn', 'Average table value');
  String teamCount(int count) => pick('$count팀', '$count nhóm', '$count teams');
  String averageTableShort(String amount) =>
      pick('평균 $amount', 'TB $amount', 'Avg $amount');
  String get hourlyTitle =>
      pick('시간대별 매출', 'Doanh thu theo giờ', 'Revenue by hour');
  String get hourlySubtitle => pick(
    '판매가 집중된 시간을 막대그래프로 확인합니다.',
    'Xác định giờ bán hàng cao điểm bằng biểu đồ cột.',
    'Identify peak sales hours with a bar chart.',
  );
  String get periodTitle =>
      pick('분석 기간', 'Khoảng phân tích', 'Analysis period');
  String get periodSubtitle => pick(
    '빠른 기간을 선택하거나 시작일과 종료일을 직접 지정하세요.',
    'Chọn khoảng nhanh hoặc nhập ngày bắt đầu và kết thúc.',
    'Choose a quick range or set custom start and end dates.',
  );
  String get oneWeek => pick('1주', '1 tuần', '1 week');
  String get twoWeeks => pick('2주', '2 tuần', '2 weeks');
  String get oneMonth => pick('한 달', '1 tháng', '1 month');
  String get from => pick('시작', 'Từ', 'From');
  String get to => pick('종료', 'Đến', 'To');
  String get apply => pick('적용', 'Áp dụng', 'Apply');
  String get loading => pick(
    '매출 분석을 불러오는 중입니다.',
    'Đang tải phân tích doanh thu.',
    'Loading revenue analysis.',
  );
  String get unavailable => pick(
    '매출 분석을 불러오지 못했습니다.',
    'Không thể tải phân tích doanh thu.',
    'Revenue analysis is unavailable.',
  );
  String get retry => pick('다시 시도', 'Thử lại', 'Retry');
  String get noDataTitle => pick(
    '선택 기간에 매출이 없습니다.',
    'Không có doanh thu trong kỳ.',
    'No revenue in this period.',
  );
  String get noDataSubtitle => pick(
    '기간을 변경하면 일자별·시간대별 매출을 확인할 수 있습니다.',
    'Đổi khoảng thời gian để xem doanh thu theo ngày và giờ.',
    'Change the period to view daily and hourly revenue.',
  );
  String get increased => pick('증가', 'Tăng', 'Up');
  String get decreased => pick('감소', 'Giảm', 'Down');
  String get unchanged => pick('변동 없음', 'Không đổi', 'No change');
}

String salesRevenueAnalysisTitle(BuildContext context) =>
    _SalesAnalysisCopy.of(context).title;

String salesRevenueAnalysisSubtitle(BuildContext context) =>
    _SalesAnalysisCopy.of(context).subtitle;
