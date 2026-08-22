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

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PaperlessOperationsDashboard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storeId != widget.storeId ||
        oldWidget.startDate != widget.startDate ||
        oldWidget.endDate != widget.endDate ||
        oldWidget.loader != widget.loader) {
      _load();
    }
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
        final range = reportUtcRange(widget.startDate, widget.endDate);
        final response = await supabase.rpc(
          'get_paperless_operations_report',
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
          startDate: widget.startDate,
          endDate: widget.endDate,
          copy: copy,
          loading: _loading,
          onRefresh: _load,
        ),
        const SizedBox(height: 12),
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
    required this.onRefresh,
  });

  final DateTime startDate;
  final DateTime endDate;
  final _PaperlessCopy copy;
  final bool loading;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    final formatter = DateFormat('yyyy.MM.dd');
    final start = formatter.format(startDate);
    final end = formatter.format(endDate);
    final period = start == end ? start : '$start – $end';
    return Container(
      key: const Key('paperless_operations_period'),
      padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PosColors.border),
      ),
      child: Row(
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
          IconButton(
            tooltip: copy.refresh,
            onPressed: loading ? null : onRefresh,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
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
        _OperationsDiningSummary(report: report, copy: copy),
        const SizedBox(height: 12),
        _OperationalFlow(report: report, copy: copy),
        const SizedBox(height: 12),
        _MenuTimingSection(report: report, copy: copy),
      ],
    );
  }
}

class _OperationsDiningSummary extends StatelessWidget {
  const _OperationsDiningSummary({required this.report, required this.copy});

  final _PaperlessReport report;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    return _DashboardSurface(
      key: const Key('paperless_operations_time_summary'),
      padding: EdgeInsets.zero,
      child: IntrinsicHeight(
        child: Row(
          children: [
            Expanded(
              child: _SummaryValue(
                label: copy.operationAverage,
                definition: copy.operationDefinition,
                seconds: report.completedOrderCount == 0
                    ? null
                    : report.averageOperationSeconds,
                sampleCount: report.completedOrderCount,
                color: PosColors.warning,
                copy: copy,
              ),
            ),
            const VerticalDivider(width: 1, thickness: 1),
            Expanded(
              child: _SummaryValue(
                label: copy.diningAverage,
                definition: copy.diningDefinition,
                seconds: report.diningOrderCount == 0
                    ? null
                    : report.averageDiningSeconds,
                sampleCount: report.diningOrderCount,
                color: PosColors.success,
                copy: copy,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SummaryValue extends StatelessWidget {
  const _SummaryValue({
    required this.label,
    required this.definition,
    required this.seconds,
    required this.sampleCount,
    required this.color,
    required this.copy,
  });

  final String label;
  final String definition;
  final int? seconds;
  final int sampleCount;
  final Color color;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 18),
      child: Column(
        children: [
          Text(
            label,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
              color: color,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            definition,
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: PosColors.textSecondary,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(
              copy.duration(seconds),
              style: Theme.of(context).textTheme.headlineLarge?.copyWith(
                color: color,
                fontSize: 27,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            copy.samples(sampleCount),
            style: Theme.of(context).textTheme.bodySmall,
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
    return _DashboardSurface(
      key: const Key('paperless_menu_operation_times'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _SectionHeading(title: copy.menuTimes, helper: copy.menuTimesHelper),
          const SizedBox(height: 6),
          if (report.menuOperationTimes.isEmpty)
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
            for (
              var index = 0;
              index < report.menuOperationTimes.length;
              index++
            ) ...[
              if (index > 0) const Divider(height: 1),
              _MenuTimingRow(
                menu: report.menuOperationTimes[index],
                copy: copy,
              ),
            ],
          const Divider(height: 1),
          Padding(
            padding: const EdgeInsets.only(top: 12),
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

class _MenuTimingRow extends StatelessWidget {
  const _MenuTimingRow({required this.menu, required this.copy});

  final _MenuOperationMetric menu;
  final _PaperlessCopy copy;

  @override
  Widget build(BuildContext context) {
    final locale = Localizations.localeOf(context).languageCode;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 13),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  menu.name(locale),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w900),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                copy.samples(menu.sampleCount),
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              _MenuStageValue(
                label: copy.station('kitchen'),
                seconds: menu.kitchenAverageSeconds,
              ),
              _MenuStageValue(
                label: copy.station('tray'),
                seconds: menu.trayAverageSeconds,
              ),
              _MenuStageValue(
                label: copy.station('floor'),
                seconds: menu.floorAverageSeconds,
              ),
              _MenuStageValue(
                label: copy.operationTotal,
                seconds: menu.operationAverageSeconds,
                emphasized: true,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _MenuStageValue extends StatelessWidget {
  const _MenuStageValue({
    required this.label,
    required this.seconds,
    this.emphasized = false,
  });

  final String label;
  final int? seconds;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final copy = _PaperlessCopy.of(context);
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        decoration: BoxDecoration(
          border: Border(
            left: emphasized
                ? const BorderSide(color: PosColors.border)
                : BorderSide.none,
          ),
        ),
        child: Column(
          children: [
            Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.labelMedium?.copyWith(
                color: emphasized ? PosColors.warning : PosColors.textSecondary,
                fontSize: 10,
              ),
            ),
            const SizedBox(height: 3),
            FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                copy.duration(seconds),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: emphasized ? PosColors.warning : PosColors.textPrimary,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
          ],
        ),
      ),
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
  const _DashboardSurface({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
  });

  final Widget child;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: padding,
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
  });

  final int orderCount;
  final int completedOrderCount;
  final int diningOrderCount;
  final int averageOperationSeconds;
  final int averageDiningSeconds;
  final String bottleneckStation;
  final List<_StationMetric> stations;
  final List<_MenuOperationMetric> menuOperationTimes;

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
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.sampleCount,
    required this.kitchenAverageSeconds,
    required this.trayAverageSeconds,
    required this.floorAverageSeconds,
    required this.operationAverageSeconds,
  });

  final String nameKo;
  final String nameVi;
  final String nameEn;
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

  factory _MenuOperationMetric.fromJson(Map<String, dynamic> json) {
    final fallback = json['name']?.toString() ?? 'Menu';
    return _MenuOperationMetric(
      nameKo: json['name_ko']?.toString() ?? fallback,
      nameVi: json['name_vi']?.toString() ?? fallback,
      nameEn: json['name_en']?.toString() ?? fallback,
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
      nameKo: name,
      nameVi: name,
      nameEn: name,
      sampleCount: _int(json['sample_count']),
      kitchenAverageSeconds: kitchen,
      trayAverageSeconds: null,
      floorAverageSeconds: null,
      operationAverageSeconds: kitchen,
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
    '페이퍼리스 운영 분석',
    'Phân tích vận hành không giấy',
    'Paperless operations',
  );
  String get subtitle => pick(
    '메뉴별 제공 과정과 고객 식사 시간을 실제 완료 이벤트로 계산합니다.',
    'Tính thời gian phục vụ từng món và thời gian dùng bữa từ sự kiện hoàn tất.',
    'Menu service and dining times calculated from completion events.',
  );
  String get selectedPeriod =>
      pick('선택 기간', 'Khoảng đã chọn', 'Selected period');
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
  String get menuTimes =>
      pick('메뉴별 제공 시간', 'Thời gian theo món', 'Time by menu');
  String get menuTimesHelper => pick(
    '완료된 메뉴의 구간별 평균',
    'TB từng chặng của món hoàn tất',
    'Stage averages for completed items',
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
