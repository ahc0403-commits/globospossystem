import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/ui/pos_design_tokens.dart';
import '../../../main.dart';
import '../../report/report_provider.dart';

String paperlessOperationsTitle(BuildContext context) =>
    _PaperlessCopy.of(context).title;

String paperlessOperationsSubtitle(BuildContext context) =>
    _PaperlessCopy.of(context).subtitle;

typedef PaperlessOperationsLoader = Future<Map<String, dynamic>> Function();

class PaperlessOperationsDashboard extends StatefulWidget {
  const PaperlessOperationsDashboard({
    super.key,
    required this.storeId,
    required this.startDate,
    required this.endDate,
    this.loader,
  });

  final String storeId;
  final DateTime startDate;
  final DateTime endDate;
  final PaperlessOperationsLoader? loader;

  @override
  State<PaperlessOperationsDashboard> createState() =>
      _PaperlessOperationsDashboardState();
}

class _PaperlessOperationsDashboardState
    extends State<PaperlessOperationsDashboard> {
  _PaperlessReport? _report;
  Object? _error;
  bool _loading = true;
  late DateTime _startDate;
  late DateTime _endDate;

  @override
  void initState() {
    super.initState();
    _startDate = DateUtils.dateOnly(widget.startDate);
    _endDate = DateUtils.dateOnly(widget.endDate);
    _load();
  }

  @override
  void didUpdateWidget(covariant PaperlessOperationsDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    final startDate = DateUtils.dateOnly(widget.startDate);
    final endDate = DateUtils.dateOnly(widget.endDate);
    final rangeChanged =
        DateUtils.dateOnly(oldWidget.startDate) != startDate ||
        DateUtils.dateOnly(oldWidget.endDate) != endDate;
    if (rangeChanged) {
      _startDate = startDate;
      _endDate = endDate;
    }
    if (oldWidget.storeId != widget.storeId ||
        rangeChanged ||
        oldWidget.loader != widget.loader) {
      _load();
    }
  }

  Future<void> _selectSingleDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _endDate,
      firstDate: DateTime(2020),
      lastDate: DateUtils.dateOnly(DateTime.now()),
      helpText: _PaperlessCopy.of(context).selectSingleDate,
    );
    if (picked == null || !mounted) return;
    _startDate = DateUtils.dateOnly(picked);
    _endDate = _startDate;
    await _load();
  }

  Future<void> _selectDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
      firstDate: DateTime(2020),
      lastDate: DateUtils.dateOnly(DateTime.now()),
      helpText: _PaperlessCopy.of(context).selectDateRange,
    );
    if (picked == null || !mounted) return;
    _startDate = DateUtils.dateOnly(picked.start);
    _endDate = DateUtils.dateOnly(picked.end);
    await _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final Map<String, dynamic> raw;
      if (widget.loader case final loader?) {
        raw = await loader();
      } else {
        final range = reportUtcRange(_startDate, _endDate);
        final response = await supabase.rpc(
          'get_paperless_operations_insights_report',
          params: {
            'p_store_id': widget.storeId,
            'p_from': range.startUtc.toIso8601String(),
            'p_to': range.endExclusiveUtc.toIso8601String(),
          },
        );
        raw = Map<String, dynamic>.from(response as Map);
      }
      final report = _PaperlessReport.fromJson(raw);
      if (!mounted) return;
      setState(() {
        _report = report;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = _PaperlessCopy.of(context);
    return Column(
      key: const Key('paperless_operations_dashboard'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PeriodBar(
          startDate: _startDate,
          endDate: _endDate,
          copy: copy,
          loading: _loading,
          onSelectSingleDate: _selectSingleDate,
          onSelectDateRange: _selectDateRange,
          onRefresh: _load,
        ),
        const SizedBox(height: 10),
        if (_loading)
          const _DashboardSurface(
            child: SizedBox(
              height: 240,
              child: Center(child: CircularProgressIndicator()),
            ),
          )
        else if (_error != null)
          _DashboardSurface(
            child: _PaperlessMessage(
              icon: Icons.info_outline_rounded,
              message: copy.unavailable,
              action: TextButton(onPressed: _load, child: Text(copy.retry)),
            ),
          )
        else if ((_report?.orderCount ?? 0) == 0)
          _DashboardSurface(
            child: _PaperlessMessage(
              icon: Icons.insights_outlined,
              message: copy.noData,
            ),
          )
        else
          _PaperlessDashboardBody(report: _report!, copy: copy),
      ],
    );
  }
}

class _PeriodBar extends StatelessWidget {
  const _PeriodBar({
    required this.startDate,
    required this.endDate,
    required this.copy,
    required this.loading,
    required this.onSelectSingleDate,
    required this.onSelectDateRange,
    required this.onRefresh,
  });

  final DateTime startDate;
  final DateTime endDate;
  final _PaperlessCopy copy;
  final bool loading;
  final VoidCallback onSelectSingleDate;
  final VoidCallback onSelectDateRange;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final formatter = DateFormat('yyyy.MM.dd');
    final start = formatter.format(startDate);
    final end = formatter.format(endDate);
    final period = start == end ? start : '$start – $end';
    final dateDetails = Row(
      children: [
        const Icon(
          Icons.calendar_today_outlined,
          size: 19,
          color: PosColors.textSecondary,
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                copy.selectedPeriod,
                style: Theme.of(context).textTheme.labelMedium,
              ),
              Text(
                period,
                style: Theme.of(
                  context,
                ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
              ),
            ],
          ),
        ),
      ],
    );
    final actions = Wrap(
      spacing: 4,
      runSpacing: 4,
      crossAxisAlignment: WrapCrossAlignment.center,
      alignment: WrapAlignment.end,
      children: [
        TextButton.icon(
          key: const Key('paperless_select_single_date'),
          onPressed: loading ? null : onSelectSingleDate,
          icon: const Icon(Icons.event_outlined, size: 18),
          label: Text(copy.singleDate),
        ),
        TextButton.icon(
          key: const Key('paperless_select_date_range'),
          onPressed: loading ? null : onSelectDateRange,
          icon: const Icon(Icons.date_range_outlined, size: 18),
          label: Text(copy.dateRange),
        ),
        IconButton(
          tooltip: copy.refresh,
          onPressed: loading ? null : onRefresh,
          icon: const Icon(Icons.refresh_rounded),
        ),
      ],
    );
    return Container(
      key: const Key('paperless_operations_period'),
      padding: const EdgeInsets.fromLTRB(12, 8, 6, 8),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PosColors.border),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final stacked =
              constraints.maxWidth < 560 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.5;
          if (stacked) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                dateDetails,
                const SizedBox(height: 4),
                Align(alignment: Alignment.centerRight, child: actions),
              ],
            );
          }
          return Row(
            children: [
              Expanded(child: dateDetails),
              const SizedBox(width: 12),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class _PaperlessDashboardBody extends StatelessWidget {
  const _PaperlessDashboardBody({required this.report, required this.copy});

  final _PaperlessReport report;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _PerformanceSummary(report: report, copy: copy),
        const SizedBox(height: 10),
        _MenuRankingsSection(report: report, copy: copy),
        const SizedBox(height: 10),
        _InsightCallout(report: report, copy: copy),
        const SizedBox(height: 10),
        _CategoryTimingSection(report: report, copy: copy),
        const SizedBox(height: 10),
        _MenuTimingSection(report: report, copy: copy),
        const SizedBox(height: 10),
        _OperationalFlow(report: report, copy: copy),
      ],
    );
  }
}

class _PerformanceSummary extends StatelessWidget {
  const _PerformanceSummary({required this.report, required this.copy});

  final _PaperlessReport report;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    final bottleneck = report.station(report.bottleneckStation);
    final bottleneckShare = report.averageOperationSeconds <= 0
        ? 0
        : (bottleneck.averageSeconds * 100 / report.averageOperationSeconds)
              .round()
              .clamp(0, 100);
    final cards = [
      _PerformanceCard(
        key: const Key('paperless_summary_service_time'),
        icon: Icons.timer_outlined,
        label: copy.averageServiceTime,
        value: copy.duration(report.averageMenuOperationSeconds),
        helper:
            '${copy.menuServiceDefinition} · '
            '${copy.samples(report.completedMenuSampleCount)}',
        color: PosColors.success,
        mutedColor: PosColors.successMuted,
      ),
      _PerformanceCard(
        key: const Key('paperless_summary_dining_time'),
        icon: Icons.restaurant_outlined,
        label: copy.diningAverage,
        value: copy.duration(
          report.diningOrderCount == 0 ? null : report.averageDiningSeconds,
        ),
        helper:
            '${copy.diningDefinition} · '
            '${copy.samples(report.diningOrderCount)}',
        color: PosColors.info,
        mutedColor: PosColors.infoMuted,
      ),
      _PerformanceCard(
        key: const Key('paperless_summary_bottleneck'),
        icon: Icons.warning_amber_rounded,
        label: copy.slowestStage,
        value: copy.station(report.bottleneckStation),
        helper: bottleneck.sampleCount == 0
            ? copy.noDataValue
            : '${copy.duration(bottleneck.averageSeconds)} · '
                  '${copy.shareOfServiceTime(bottleneckShare)}',
        color: PosColors.warning,
        mutedColor: PosColors.warningMuted,
      ),
      _PerformanceCard(
        key: const Key('paperless_summary_samples'),
        icon: Icons.analytics_outlined,
        label: copy.analysisSamples,
        value: copy.count(report.completedMenuSampleCount),
        helper: copy.completedMenuSamples,
        color: PosColors.accent,
        mutedColor: PosColors.accentMuted,
      ),
    ];

    return _DashboardSurface(
      key: const Key('paperless_operations_time_summary'),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          final textScale = MediaQuery.textScalerOf(context).scale(1);
          final columns = width >= 960 && textScale <= 1.35
              ? 4
              : width >= 560 && textScale <= 1.5
              ? 2
              : width >= 320 && textScale <= 1.25
              ? 2
              : 1;
          const spacing = 8.0;
          final cardWidth = (width - (columns - 1) * spacing) / columns;
          return Wrap(
            spacing: spacing,
            runSpacing: spacing,
            children: [
              for (final card in cards) SizedBox(width: cardWidth, child: card),
            ],
          );
        },
      ),
    );
  }
}

class _PerformanceCard extends StatelessWidget {
  const _PerformanceCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.helper,
    required this.color,
    required this.mutedColor,
  });

  final IconData icon;
  final String label;
  final String value;
  final String helper;
  final Color color;
  final Color mutedColor;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(minHeight: 104),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: PosColors.canvasAlt,
        borderRadius: BorderRadius.circular(13),
        border: Border.all(color: PosColors.border),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 34,
            height: 34,
            decoration: BoxDecoration(
              color: mutedColor,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: color, size: 19),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 3),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    value,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  helper,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuRankingsSection extends StatelessWidget {
  const _MenuRankingsSection({required this.report, required this.copy});

  final _PaperlessReport report;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    final fastest = _RankingCard(
      key: const Key('paperless_fastest_menu_ranking'),
      title: copy.fastestMenus,
      helper: copy.rankingHelper,
      icon: Icons.bolt_rounded,
      color: PosColors.success,
      mutedColor: PosColors.successMuted,
      metrics: report.fastestMenus,
      copy: copy,
    );
    final slowest = _RankingCard(
      key: const Key('paperless_slowest_menu_ranking'),
      title: copy.slowestMenus,
      helper: copy.rankingHelper,
      icon: Icons.hourglass_bottom_rounded,
      color: PosColors.danger,
      mutedColor: PosColors.dangerMuted,
      metrics: report.slowestMenus,
      copy: copy,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 820) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [fastest, const SizedBox(height: 12), slowest],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(child: fastest),
            const SizedBox(width: 12),
            Expanded(child: slowest),
          ],
        );
      },
    );
  }
}

class _RankingCard extends StatelessWidget {
  const _RankingCard({
    super.key,
    required this.title,
    required this.helper,
    required this.icon,
    required this.color,
    required this.mutedColor,
    required this.metrics,
    required this.copy,
  });

  final String title;
  final String helper;
  final IconData icon;
  final Color color;
  final Color mutedColor;
  final List<_MenuOperationMetric> metrics;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    final maxSeconds = metrics.fold<int>(
      0,
      (current, metric) => metric.operationAverageSeconds > current
          ? metric.operationAverageSeconds
          : current,
    );
    return _DashboardSurface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: mutedColor,
                  borderRadius: BorderRadius.circular(9),
                ),
                child: Icon(icon, color: color, size: 19),
              ),
              const SizedBox(width: 9),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        color: color,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      helper,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (metrics.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Text(
                copy.noCompletedMenus,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: PosColors.textSecondary,
                ),
              ),
            )
          else
            for (var index = 0; index < metrics.length; index++)
              _RankingRow(
                rank: index + 1,
                metric: metrics[index],
                maxSeconds: maxSeconds,
                color: color,
                mutedColor: mutedColor,
                copy: copy,
              ),
        ],
      ),
    );
  }
}

class _RankingRow extends StatelessWidget {
  const _RankingRow({
    required this.rank,
    required this.metric,
    required this.maxSeconds,
    required this.color,
    required this.mutedColor,
    required this.copy,
  });

  final int rank;
  final _MenuOperationMetric metric;
  final int maxSeconds;
  final Color color;
  final Color mutedColor;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact =
              constraints.maxWidth < 500 ||
              MediaQuery.textScalerOf(context).scale(1) > 1.4;
          final badge = Container(
            width: 25,
            height: 25,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: mutedColor,
              borderRadius: BorderRadius.circular(7),
            ),
            child: Text(
              '$rank',
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: color,
                fontWeight: FontWeight.w900,
              ),
            ),
          );
          final bar = _DurationBar(
            seconds: metric.operationAverageSeconds,
            maxSeconds: maxSeconds,
            color: color,
          );
          if (compact) {
            return Column(
              children: [
                Row(
                  children: [
                    badge,
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        metric.name(locale),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      copy.duration(metric.operationAverageSeconds),
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Padding(
                  padding: const EdgeInsets.only(left: 33),
                  child: Row(
                    children: [
                      Expanded(child: bar),
                      const SizedBox(width: 8),
                      Text(
                        copy.samples(metric.sampleCount),
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: PosColors.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            );
          }
          return Row(
            children: [
              badge,
              const SizedBox(width: 8),
              SizedBox(
                width: 126,
                child: Text(
                  metric.name(locale),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w800),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(child: bar),
              const SizedBox(width: 8),
              SizedBox(
                width: 78,
                child: Text(
                  copy.duration(metric.operationAverageSeconds),
                  textAlign: TextAlign.right,
                  style: Theme.of(
                    context,
                  ).textTheme.bodySmall?.copyWith(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: 58,
                child: Text(
                  copy.samples(metric.sampleCount),
                  textAlign: TextAlign.right,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textSecondary,
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DurationBar extends StatelessWidget {
  const _DurationBar({
    required this.seconds,
    required this.maxSeconds,
    required this.color,
  });

  final int seconds;
  final int maxSeconds;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final fraction = maxSeconds <= 0 || seconds <= 0
        ? 0.0
        : (seconds / maxSeconds).clamp(0.06, 1.0).toDouble();
    return ClipRRect(
      borderRadius: BorderRadius.circular(999),
      child: SizedBox(
        height: 8,
        child: Stack(
          fit: StackFit.expand,
          children: [
            Container(color: PosColors.panelMuted),
            Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: fraction,
                heightFactor: 1,
                child: ColoredBox(color: color),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InsightCallout extends StatelessWidget {
  const _InsightCallout({required this.report, required this.copy});

  final _PaperlessReport report;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    final slowestNames = report.slowestMenus
        .take(2)
        .map((metric) => metric.name(locale))
        .toList(growable: false);
    final message = slowestNames.isEmpty
        ? copy.noCompletedMenus
        : copy.insightMessage(
            copy.station(report.bottleneckStation),
            slowestNames,
          );
    return Container(
      key: const Key('paperless_operations_insight'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: PosColors.warningMuted,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFFF2B36B)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.lightbulb_outline_rounded, color: PosColors.warning),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  copy.improvementPoint,
                  style: Theme.of(context).textTheme.titleSmall?.copyWith(
                    color: PosColors.warning,
                    fontWeight: FontWeight.w900,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  message,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.textPrimary,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryTimingSection extends StatelessWidget {
  const _CategoryTimingSection({required this.report, required this.copy});

  final _PaperlessReport report;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    final metrics = report.categoryOperationTimes.toList(growable: false)
      ..sort((left, right) {
        final duration = right.operationAverageSeconds.compareTo(
          left.operationAverageSeconds,
        );
        return duration != 0 ? duration : left.nameKo.compareTo(right.nameKo);
      });
    final benchmarkSeconds = report.averageMenuOperationSeconds ?? 0;
    final maxSeconds = metrics.fold<int>(
      benchmarkSeconds,
      (current, metric) => metric.operationAverageSeconds > current
          ? metric.operationAverageSeconds
          : current,
    );
    return _DashboardSurface(
      key: const Key('paperless_category_operation_times'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionHeading(
            title: copy.categoryTimes,
            helper: copy.categoryTimesHelper(
              copy.duration(report.averageMenuOperationSeconds),
            ),
          ),
          const SizedBox(height: 14),
          if (metrics.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Text(
                copy.noCategoryData,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: PosColors.textSecondary,
                ),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final useTwoColumns =
                    constraints.maxWidth >= 900 &&
                    MediaQuery.textScalerOf(context).scale(1) <= 1.4;
                const spacing = 12.0;
                final itemWidth = useTwoColumns
                    ? (constraints.maxWidth - spacing) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (var index = 0; index < metrics.length; index++)
                      SizedBox(
                        width: itemWidth,
                        child: _CategoryTimingRow(
                          rank: index + 1,
                          metric: metrics[index],
                          maxSeconds: maxSeconds,
                          benchmarkSeconds: benchmarkSeconds,
                          copy: copy,
                        ),
                      ),
                  ],
                );
              },
            ),
        ],
      ),
    );
  }
}

class _CategoryTimingRow extends StatelessWidget {
  const _CategoryTimingRow({
    required this.rank,
    required this.metric,
    required this.maxSeconds,
    required this.benchmarkSeconds,
    required this.copy,
  });

  final int rank;
  final _CategoryOperationMetric metric;
  final int maxSeconds;
  final int benchmarkSeconds;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    final color =
        benchmarkSeconds > 0 &&
            metric.operationAverageSeconds > benchmarkSeconds
        ? PosColors.warning
        : PosColors.success;
    final fraction = maxSeconds <= 0 || metric.operationAverageSeconds <= 0
        ? 0.0
        : (metric.operationAverageSeconds / maxSeconds)
              .clamp(0.04, 1.0)
              .toDouble();
    final benchmarkFraction = maxSeconds <= 0
        ? 0.0
        : (benchmarkSeconds / maxSeconds).clamp(0.0, 1.0).toDouble();
    return Container(
      key: Key('paperless_category_timing_${metric.categoryKey}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: PosColors.panelMuted,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact =
                  constraints.maxWidth < 440 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.4;
              final name = Row(
                children: [
                  Container(
                    constraints: const BoxConstraints(minWidth: 30),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: PosColors.surface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: PosColors.border),
                    ),
                    child: Text(
                      '#$rank',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: PosColors.textSecondary,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Text(
                      metric.name(locale),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ],
              );
              final details = Wrap(
                spacing: 10,
                runSpacing: 3,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    copy.duration(metric.operationAverageSeconds),
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: color,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    copy.samples(metric.sampleCount),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                    ),
                  ),
                ],
              );
              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [name, const SizedBox(height: 3), details],
                );
              }
              return Row(
                children: [
                  Expanded(child: name),
                  const SizedBox(width: 8),
                  details,
                ],
              );
            },
          ),
          const SizedBox(height: 7),
          LayoutBuilder(
            builder: (context, constraints) {
              final markerLeft = (constraints.maxWidth * benchmarkFraction)
                  .clamp(0.0, constraints.maxWidth - 2)
                  .toDouble();
              return ClipRRect(
                borderRadius: BorderRadius.circular(999),
                child: SizedBox(
                  height: 10,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      Container(color: PosColors.surface),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: fraction,
                          heightFactor: 1,
                          child: ColoredBox(color: color),
                        ),
                      ),
                      if (benchmarkSeconds > 0)
                        Positioned(
                          left: markerLeft,
                          top: 0,
                          bottom: 0,
                          child: Container(width: 2, color: PosColors.danger),
                        ),
                    ],
                  ),
                ),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _OperationalFlow extends StatelessWidget {
  const _OperationalFlow({required this.report, required this.copy});

  final _PaperlessReport report;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    final stations = [
      'kitchen',
      'tray',
      'floor',
    ].map(report.station).toList(growable: false);
    return _DashboardSurface(
      key: const Key('paperless_operations_flow'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionHeading(
            title: copy.operationalFlow,
            helper: copy.stageAverageAndBacklog,
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              for (var index = 0; index < stations.length; index++) ...[
                Expanded(
                  child: _StationStep(
                    station: stations[index],
                    label: copy.station(stations[index].station),
                    bottleneck:
                        stations[index].station == report.bottleneckStation,
                    copy: copy,
                  ),
                ),
                if (index < stations.length - 1)
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 3),
                    child: Icon(
                      Icons.arrow_forward_rounded,
                      size: 19,
                      color: PosColors.textMuted,
                    ),
                  ),
              ],
            ],
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: PosColors.warningMuted,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    copy.operationEquation,
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  copy.duration(
                    report.completedOrderCount == 0
                        ? null
                        : report.averageOperationSeconds,
                  ),
                  style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    color: PosColors.warning,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StationStep extends StatelessWidget {
  const _StationStep({
    required this.station,
    required this.label,
    required this.bottleneck,
    required this.copy,
  });

  final _StationMetric station;
  final String label;
  final bool bottleneck;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('paperless_station_${station.station}'),
      constraints: const BoxConstraints(minHeight: 104),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      decoration: BoxDecoration(
        color: bottleneck ? PosColors.warningMuted : PosColors.canvasAlt,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: bottleneck ? const Color(0xFFF2B36B) : PosColors.border,
        ),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: bottleneck ? PosColors.warning : PosColors.textPrimary,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 7),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              copy.duration(
                station.sampleCount == 0 ? null : station.averageSeconds,
              ),
              style: Theme.of(
                context,
              ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
            ),
          ),
          const SizedBox(height: 7),
          Text(
            copy.backlogCount(station.backlogQuantity),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              fontSize: 11,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _MenuTimingSection extends StatelessWidget {
  const _MenuTimingSection({required this.report, required this.copy});

  final _PaperlessReport report;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    final metrics = report.menuOperationTimes.toList(growable: false)
      ..sort((left, right) {
        final duration = right.operationAverageSeconds.compareTo(
          left.operationAverageSeconds,
        );
        return duration != 0 ? duration : left.nameKo.compareTo(right.nameKo);
      });
    final maxSeconds = metrics.fold<int>(
      0,
      (current, metric) => metric.operationAverageSeconds > current
          ? metric.operationAverageSeconds
          : current,
    );
    return _DashboardSurface(
      key: const Key('paperless_menu_operation_times'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionHeading(title: copy.menuTimes, helper: copy.menuTimesHelper),
          const SizedBox(height: 9),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              _StageLegend(
                color: PosColors.warning,
                label: copy.station('kitchen'),
              ),
              _StageLegend(color: PosColors.info, label: copy.station('tray')),
              _StageLegend(
                color: PosColors.success,
                label: copy.station('floor'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (metrics.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 28),
              child: Text(
                copy.noCompletedMenus,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: PosColors.textSecondary,
                ),
              ),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final useTwoColumns =
                    constraints.maxWidth >= 1000 &&
                    MediaQuery.textScalerOf(context).scale(1) <= 1.35;
                const spacing = 12.0;
                final itemWidth = useTwoColumns
                    ? (constraints.maxWidth - spacing) / 2
                    : constraints.maxWidth;
                return Wrap(
                  spacing: spacing,
                  runSpacing: spacing,
                  children: [
                    for (var index = 0; index < metrics.length; index++)
                      SizedBox(
                        width: itemWidth,
                        child: _MenuTimingRow(
                          rank: index + 1,
                          menu: metrics[index],
                          maxSeconds: maxSeconds,
                          copy: copy,
                        ),
                      ),
                  ],
                );
              },
            ),
          Container(
            margin: const EdgeInsets.only(top: 14),
            padding: const EdgeInsets.only(top: 12),
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: PosColors.border)),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Icon(
                  Icons.info_outline_rounded,
                  size: 18,
                  color: PosColors.textSecondary,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    copy.diningFootnote,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _StageLegend extends StatelessWidget {
  const _StageLegend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Text(
          label,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: PosColors.textSecondary,
            fontWeight: FontWeight.w700,
          ),
        ),
      ],
    );
  }
}

class _MenuTimingRow extends StatelessWidget {
  const _MenuTimingRow({
    required this.rank,
    required this.menu,
    required this.maxSeconds,
    required this.copy,
  });

  final int rank;
  final _MenuOperationMetric menu;
  final int maxSeconds;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    return Container(
      key: Key('paperless_menu_timing_${menu.menuKey}'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          LayoutBuilder(
            builder: (context, constraints) {
              final compact =
                  constraints.maxWidth < 480 ||
                  MediaQuery.textScalerOf(context).scale(1) > 1.4;
              final name = Row(
                children: [
                  Container(
                    constraints: const BoxConstraints(minWidth: 30),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: PosColors.surface,
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(color: PosColors.border),
                    ),
                    child: Text(
                      '#$rank',
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.labelSmall?.copyWith(
                        color: PosColors.textSecondary,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  const SizedBox(width: 9),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          menu.name(locale),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodyMedium
                              ?.copyWith(fontWeight: FontWeight.w900),
                        ),
                        Text(
                          menu.categoryName(locale),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: PosColors.textSecondary),
                        ),
                      ],
                    ),
                  ),
                ],
              );
              final total = Wrap(
                spacing: 10,
                runSpacing: 3,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  Text(
                    copy.duration(menu.operationAverageSeconds),
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                      color: PosColors.warning,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                  Text(
                    copy.samples(menu.sampleCount),
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                    ),
                  ),
                ],
              );
              if (compact) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [name, const SizedBox(height: 5), total],
                );
              }
              return Row(
                children: [
                  Expanded(child: name),
                  const SizedBox(width: 12),
                  total,
                ],
              );
            },
          ),
          const SizedBox(height: 9),
          _StageDistributionBar(menu: menu, maxSeconds: maxSeconds),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: [
              _MenuStageValue(
                label: copy.station('kitchen'),
                seconds: menu.kitchenAverageSeconds,
                color: PosColors.warning,
              ),
              _MenuStageValue(
                label: copy.station('tray'),
                seconds: menu.trayAverageSeconds,
                color: PosColors.info,
              ),
              _MenuStageValue(
                label: copy.station('floor'),
                seconds: menu.floorAverageSeconds,
                color: PosColors.success,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _StageDistributionBar extends StatelessWidget {
  const _StageDistributionBar({required this.menu, required this.maxSeconds});

  final _MenuOperationMetric menu;
  final int maxSeconds;

  @override
  Widget build(BuildContext context) {
    final segments = <({Color color, int seconds})>[
      if ((menu.kitchenAverageSeconds ?? 0) > 0)
        (color: PosColors.warning, seconds: menu.kitchenAverageSeconds!),
      if ((menu.trayAverageSeconds ?? 0) > 0)
        (color: PosColors.info, seconds: menu.trayAverageSeconds!),
      if ((menu.floorAverageSeconds ?? 0) > 0)
        (color: PosColors.success, seconds: menu.floorAverageSeconds!),
    ];
    final totalFraction = maxSeconds <= 0 || menu.operationAverageSeconds <= 0
        ? 0.0
        : (menu.operationAverageSeconds / maxSeconds)
              .clamp(0.02, 1.0)
              .toDouble();
    return ClipRRect(
      key: Key('paperless_menu_bar_${menu.menuKey}'),
      borderRadius: BorderRadius.circular(999),
      child: Container(
        height: 14,
        color: PosColors.panelMuted,
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            key: Key('paperless_menu_bar_fill_${menu.menuKey}'),
            widthFactor: totalFraction,
            heightFactor: 1,
            child: segments.isEmpty
                ? const ColoredBox(color: PosColors.warning)
                : Row(
                    children: [
                      for (final segment in segments)
                        Expanded(
                          flex: segment.seconds,
                          child: ColoredBox(color: segment.color),
                        ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}

class _MenuStageValue extends StatelessWidget {
  const _MenuStageValue({
    required this.label,
    required this.seconds,
    required this.color,
  });

  final String label;
  final int? seconds;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final copy = _PaperlessCopy.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            '$label ${copy.duration(seconds)}',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: PosColors.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
      ],
    );
  }
}

class _SectionHeading extends StatelessWidget {
  const _SectionHeading({required this.title, required this.helper});

  final String title;
  final String helper;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 2,
      children: [
        Text(
          title,
          style: Theme.of(
            context,
          ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
        ),
        Text(
          helper,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
        ),
      ],
    );
  }
}

class _DashboardSurface extends StatelessWidget {
  const _DashboardSurface({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PosColors.border),
      ),
      child: child,
    );
  }
}

class _PaperlessMessage extends StatelessWidget {
  const _PaperlessMessage({
    required this.icon,
    required this.message,
    this.action,
  });

  final IconData icon;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => ConstrainedBox(
    constraints: const BoxConstraints(minHeight: 130),
    child: Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: PosColors.textSecondary),
          const SizedBox(height: 6),
          Text(message, textAlign: TextAlign.center),
          if (action != null) action!,
        ],
      ),
    ),
  );
}

class _PaperlessReport {
  const _PaperlessReport({
    required this.orderCount,
    required this.completedOrderCount,
    required this.diningOrderCount,
    required this.averageOperationSeconds,
    required this.averageDiningSeconds,
    required this.bottleneckStation,
    required this.stations,
    required this.menuOperationTimes,
    required this.categoryOperationTimes,
  });

  final int orderCount;
  final int completedOrderCount;
  final int diningOrderCount;
  final int averageOperationSeconds;
  final int averageDiningSeconds;
  final String bottleneckStation;
  final List<_StationMetric> stations;
  final List<_MenuOperationMetric> menuOperationTimes;
  final List<_CategoryOperationMetric> categoryOperationTimes;

  int get completedMenuSampleCount => menuOperationTimes.fold<int>(
    0,
    (total, metric) => total + metric.sampleCount,
  );

  int? get averageMenuOperationSeconds {
    final sampleCount = completedMenuSampleCount;
    if (sampleCount == 0) return null;
    final weightedSeconds = menuOperationTimes.fold<int>(
      0,
      (total, metric) =>
          total + metric.operationAverageSeconds * metric.sampleCount,
    );
    return (weightedSeconds / sampleCount).round();
  }

  List<_MenuOperationMetric> get fastestMenus => _rankedMenus((left, right) {
    final duration = left.operationAverageSeconds.compareTo(
      right.operationAverageSeconds,
    );
    return duration != 0 ? duration : left.nameKo.compareTo(right.nameKo);
  });

  List<_MenuOperationMetric> get slowestMenus => _rankedMenus((left, right) {
    final duration = right.operationAverageSeconds.compareTo(
      left.operationAverageSeconds,
    );
    return duration != 0 ? duration : left.nameKo.compareTo(right.nameKo);
  });

  List<_MenuOperationMetric> _rankedMenus(
    int Function(_MenuOperationMetric, _MenuOperationMetric) compare,
  ) {
    final ranked =
        menuOperationTimes
            .where(
              (metric) =>
                  metric.sampleCount > 0 && metric.operationAverageSeconds >= 0,
            )
            .toList(growable: true)
          ..sort(compare);
    return ranked.take(5).toList(growable: false);
  }

  _StationMetric station(String value) => stations.firstWhere(
    (station) => station.station == value,
    orElse: () => _StationMetric.empty(value),
  );

  factory _PaperlessReport.fromJson(Map<String, dynamic> json) {
    final menuRows = _maps(
      json['menu_operation_times'],
    ).map(_MenuOperationMetric.fromJson).toList(growable: false);
    final legacyRows = _maps(
      json['menu_kitchen_times'],
    ).map(_MenuOperationMetric.fromLegacyJson).toList(growable: false);
    return _PaperlessReport(
      orderCount: _int(json['order_count']),
      completedOrderCount: _int(json['completed_order_count']),
      diningOrderCount: _int(json['dining_order_count']),
      averageOperationSeconds: _int(
        json['average_operation_seconds'] ?? json['average_total_seconds'],
      ),
      averageDiningSeconds: _int(json['average_dining_seconds']),
      bottleneckStation: json['bottleneck_station']?.toString() ?? 'none',
      stations: _maps(
        json['stations'],
      ).map(_StationMetric.fromJson).toList(growable: false),
      menuOperationTimes: menuRows.isEmpty ? legacyRows : menuRows,
      categoryOperationTimes: _maps(
        json['category_operation_times'],
      ).map(_CategoryOperationMetric.fromJson).toList(growable: false),
    );
  }
}

class _StationMetric {
  const _StationMetric({
    required this.station,
    required this.sampleCount,
    required this.averageSeconds,
    required this.backlogQuantity,
  });

  final String station;
  final int sampleCount;
  final int averageSeconds;
  final int backlogQuantity;

  factory _StationMetric.empty(String station) => _StationMetric(
    station: station,
    sampleCount: 0,
    averageSeconds: 0,
    backlogQuantity: 0,
  );

  factory _StationMetric.fromJson(Map<String, dynamic> json) => _StationMetric(
    station: json['station']?.toString() ?? 'none',
    sampleCount: _int(json['sample_count']),
    averageSeconds: _int(json['average_seconds'] ?? json['p50_seconds']),
    backlogQuantity: _int(json['backlog_quantity']),
  );
}

class _MenuOperationMetric {
  const _MenuOperationMetric({
    required this.menuKey,
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.categoryNameKo,
    required this.categoryNameVi,
    required this.categoryNameEn,
    required this.sampleCount,
    required this.kitchenAverageSeconds,
    required this.trayAverageSeconds,
    required this.floorAverageSeconds,
    required this.operationAverageSeconds,
  });

  final String menuKey;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final String categoryNameKo;
  final String categoryNameVi;
  final String categoryNameEn;
  final int sampleCount;
  final int? kitchenAverageSeconds;
  final int? trayAverageSeconds;
  final int? floorAverageSeconds;
  final int operationAverageSeconds;

  String name(String languageCode) => switch (languageCode) {
    'vi' => nameVi,
    'en' => nameEn,
    _ => nameKo,
  };

  String categoryName(String languageCode) => switch (languageCode) {
    'vi' => categoryNameVi,
    'en' => categoryNameEn,
    _ => categoryNameKo,
  };

  factory _MenuOperationMetric.fromJson(Map<String, dynamic> json) {
    final fallback = json['name']?.toString() ?? 'Menu';
    return _MenuOperationMetric(
      menuKey: json['menu_key']?.toString() ?? fallback,
      nameKo: json['name_ko']?.toString() ?? fallback,
      nameVi: json['name_vi']?.toString() ?? fallback,
      nameEn: json['name_en']?.toString() ?? fallback,
      categoryNameKo: json['category_name_ko']?.toString() ?? '미분류',
      categoryNameVi: json['category_name_vi']?.toString() ?? 'Chưa phân loại',
      categoryNameEn: json['category_name_en']?.toString() ?? 'Uncategorized',
      sampleCount: _int(json['sample_count']),
      kitchenAverageSeconds: _nullableInt(json['kitchen_average_seconds']),
      trayAverageSeconds: _nullableInt(json['tray_average_seconds']),
      floorAverageSeconds: _nullableInt(json['floor_average_seconds']),
      operationAverageSeconds: _int(json['operation_average_seconds']),
    );
  }

  factory _MenuOperationMetric.fromLegacyJson(Map<String, dynamic> json) {
    final name = json['name']?.toString() ?? 'Menu';
    final kitchen = _int(json['average_seconds']);
    return _MenuOperationMetric(
      menuKey: name,
      nameKo: name,
      nameVi: name,
      nameEn: name,
      categoryNameKo: '미분류',
      categoryNameVi: 'Chưa phân loại',
      categoryNameEn: 'Uncategorized',
      sampleCount: _int(json['sample_count']),
      kitchenAverageSeconds: kitchen,
      trayAverageSeconds: null,
      floorAverageSeconds: null,
      operationAverageSeconds: kitchen,
    );
  }
}

class _CategoryOperationMetric {
  const _CategoryOperationMetric({
    required this.categoryKey,
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.sampleCount,
    required this.operationAverageSeconds,
  });

  final String categoryKey;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final int sampleCount;
  final int operationAverageSeconds;

  String name(String languageCode) => switch (languageCode) {
    'vi' => nameVi,
    'en' => nameEn,
    _ => nameKo,
  };

  factory _CategoryOperationMetric.fromJson(Map<String, dynamic> json) {
    final fallback = json['name']?.toString() ?? 'Uncategorized';
    return _CategoryOperationMetric(
      categoryKey: json['category_key']?.toString() ?? 'uncategorized',
      nameKo: json['name_ko']?.toString() ?? fallback,
      nameVi: json['name_vi']?.toString() ?? fallback,
      nameEn: json['name_en']?.toString() ?? fallback,
      sampleCount: _int(json['sample_count']),
      operationAverageSeconds: _int(json['operation_average_seconds']),
    );
  }
}

class _PaperlessCopy {
  const _PaperlessCopy(this.code);
  final String code;

  static _PaperlessCopy of(BuildContext context) =>
      _PaperlessCopy(Localizations.localeOf(context).languageCode);
  String pick(String ko, String vi, String en) => switch (code) {
    'vi' => vi,
    'en' => en,
    _ => ko,
  };

  String get title => pick(
    '운영 성과 분석',
    'Phân tích hiệu suất vận hành',
    'Operations performance',
  );
  String get subtitle => pick(
    '메뉴 제공 속도와 병목을 실제 완료 이벤트로 분석합니다.',
    'Phân tích tốc độ phục vụ và điểm nghẽn từ sự kiện hoàn tất thực tế.',
    'Analyze service speed and bottlenecks from completion events.',
  );
  String get selectedPeriod =>
      pick('선택 기간', 'Khoảng đã chọn', 'Selected period');
  String get singleDate => pick('특정일', 'Một ngày', 'Single date');
  String get dateRange => pick('기간', 'Khoảng ngày', 'Date range');
  String get selectSingleDate =>
      pick('조회할 날짜 선택', 'Chọn ngày cần xem', 'Select date to view');
  String get selectDateRange => pick(
    '조회할 기간 선택',
    'Chọn khoảng ngày cần xem',
    'Select date range to view',
  );
  String get refresh => pick('새로고침', 'Làm mới', 'Refresh');
  String get retry => pick('다시 시도', 'Thử lại', 'Retry');
  String get unavailable => pick(
    '운영 분석을 불러오지 못했습니다. 매출 보고서는 계속 사용할 수 있습니다.',
    'Không thể tải phân tích vận hành. Báo cáo doanh thu vẫn dùng được.',
    'Operations analytics is unavailable. Sales reports remain usable.',
  );
  String get noData => pick(
    '선택 기간에 페이퍼리스 주문 데이터가 없습니다.',
    'Không có dữ liệu đơn không giấy trong khoảng đã chọn.',
    'No paperless order data in the selected range.',
  );
  String get averageServiceTime =>
      pick('평균 제공시간', 'Thời gian phục vụ TB', 'Average service time');
  String get menuServiceDefinition => pick(
    '메뉴 접수부터 제공 완료까지',
    'Từ khi nhận món đến khi phục vụ xong',
    'Menu received to service completion',
  );
  String get slowestStage =>
      pick('가장 느린 구간', 'Chặng chậm nhất', 'Slowest stage');
  String get analysisSamples =>
      pick('분석 표본', 'Mẫu phân tích', 'Analysis samples');
  String get completedMenuSamples =>
      pick('제공 완료 메뉴', 'Món đã phục vụ xong', 'Completed menu items');
  String get noDataValue => pick('데이터 없음', 'Không có dữ liệu', 'No data');
  String count(int value) => pick('$value건', '$value mục', '$value items');
  String shareOfServiceTime(int percent) => pick(
    '전체 제공시간의 $percent%',
    '$percent% tổng thời gian phục vụ',
    '$percent% of service time',
  );
  String get fastestMenus => pick(
    '가장 빨리 나간 메뉴 TOP 5',
    'TOP 5 món ra nhanh nhất',
    'Top 5 fastest menus',
  );
  String get slowestMenus => pick(
    '가장 늦게 나간 메뉴 TOP 5',
    'TOP 5 món ra chậm nhất',
    'Top 5 slowest menus',
  );
  String get rankingHelper => pick(
    '완료 메뉴의 평균 제공시간 · 표본 수',
    'Thời gian phục vụ TB · số mẫu',
    'Average service time · samples',
  );
  String get improvementPoint =>
      pick('오늘의 개선 포인트', 'Điểm cần cải thiện', 'Improvement focus');
  String insightMessage(String stationName, List<String> menuNames) {
    if (menuNames.isEmpty) {
      return pick(
        '$stationName 구간의 대기와 완료 흐름을 확인하세요.',
        'Kiểm tra hàng chờ và luồng hoàn tất tại chặng $stationName.',
        'Review the queue and completion flow at $stationName.',
      );
    }
    final joined = menuNames.join(' · ');
    return pick(
      '$stationName 구간이 가장 오래 걸립니다. $joined 제공 흐름을 먼저 확인하세요.',
      '$stationName là chặng chậm nhất. Hãy kiểm tra luồng phục vụ của $joined trước.',
      '$stationName is the slowest stage. Review the service flow for $joined first.',
    );
  }

  String get categoryTimes => pick(
    '카테고리별 평균 제공시간',
    'Thời gian phục vụ TB theo danh mục',
    'Average service time by category',
  );
  String categoryTimesHelper(String benchmark) => pick(
    '완료 메뉴 기준 · 빨간선은 전체 평균 $benchmark',
    'Món hoàn tất · vạch đỏ là TB chung $benchmark',
    'Completed items · red marker is overall average $benchmark',
  );
  String get noCategoryData => pick(
    '카테고리별 완료 메뉴 표본이 없습니다.',
    'Chưa có mẫu món hoàn tất theo danh mục.',
    'No completed menu samples by category.',
  );
  String get operationAverage =>
      pick('운영 평균', 'TB vận hành', 'Average operation');
  String get operationDefinition => pick(
    '주문 접수부터 모든 음식 전달까지',
    'Từ nhận đơn đến khi giao đủ món',
    'Order received to all food delivered',
  );
  String get diningAverage => pick('식사 평균', 'TB dùng bữa', 'Average dining');
  String get diningDefinition => pick(
    '모든 음식 제공 완료 후 결제까지',
    'Từ khi giao đủ món đến thanh toán',
    'All food delivered to payment',
  );
  String samples(int count) =>
      pick('표본 $count건', 'Mẫu $count', '$count samples');
  String duration(int? seconds) {
    if (seconds == null || seconds < 0) return '—';
    if (seconds < 60) return pick('$seconds초', '${seconds}s', '${seconds}s');
    final minutes = seconds ~/ 60;
    final remainder = seconds % 60;
    if (remainder == 0) {
      return pick('$minutes분', '${minutes}p', '${minutes}m');
    }
    return pick(
      '$minutes분 $remainder초',
      '${minutes}p ${remainder}s',
      '${minutes}m ${remainder}s',
    );
  }

  String get operationalFlow =>
      pick('운영 흐름', 'Luồng vận hành', 'Operation flow');
  String get stageAverageAndBacklog => pick(
    '구간별 평균 · 현재 대기',
    'TB từng chặng · đang chờ',
    'Stage average · current backlog',
  );
  String backlogCount(int count) =>
      pick('대기 $count', 'Chờ $count', '$count waiting');
  String get operationEquation => pick(
    '주방 + 트레이 + 층 서빙 = 운영 합계',
    'Bếp + khay + tầng = tổng vận hành',
    'Kitchen + tray + floor = operation total',
  );
  String get menuTimes => pick(
    '메뉴별 평균 제공시간',
    'Thời gian phục vụ TB theo món',
    'Average service time by menu',
  );
  String get menuTimesHelper => pick(
    '느린 순 · 막대 길이는 전체 제공시간, 색상은 구간별 평균',
    'Chậm trước · độ dài là tổng thời gian, màu là TB từng chặng',
    'Slowest first · bar length is total time, colors are stage averages',
  );
  String get noCompletedMenus => pick(
    '제공 완료된 메뉴 표본이 없습니다.',
    'Chưa có mẫu món đã phục vụ xong.',
    'No completed menu samples.',
  );
  String get operationTotal => pick('운영 합계', 'Tổng', 'Total');
  String get diningFootnote => pick(
    '식사 시간은 모든 메뉴 제공 완료 후 결제까지의 평균입니다. 제공 중이거나 결제 전인 주문은 제외됩니다.',
    'Thời gian dùng bữa là trung bình từ lúc giao đủ món đến thanh toán. Đơn đang phục vụ hoặc chưa thanh toán bị loại trừ.',
    'Dining time averages full delivery to payment. In-service and unpaid orders are excluded.',
  );
  String station(String value) => switch (value) {
    'kitchen' => pick('주방', 'Bếp', 'Kitchen'),
    'tray' => pick('트레이', 'Khay', 'Tray'),
    'floor' => pick('층 서빙', 'Tầng', 'Floor'),
    _ => pick('데이터 없음', 'Không có dữ liệu', 'No data'),
  };
}

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false)
    : const [];

int _int(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};

int? _nullableInt(Object? value) => value == null ? null : _int(value);
