import 'package:flutter/material.dart';

import '../../../core/ui/pos_design_tokens.dart';
import '../../../main.dart';
import '../../report/report_provider.dart';

String paperlessOperationsTitle(BuildContext context) =>
    _PaperlessCopy.of(context).title;

String paperlessOperationsSubtitle(BuildContext context) =>
    _PaperlessCopy.of(context).subtitle;

class PaperlessOperationsDashboard extends StatefulWidget {
  const PaperlessOperationsDashboard({
    super.key,
    required this.storeId,
    required this.startDate,
    required this.endDate,
  });

  final String storeId;
  final DateTime startDate;
  final DateTime endDate;

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
        oldWidget.endDate != widget.endDate) {
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final range = reportUtcRange(widget.startDate, widget.endDate);
      final raw = await supabase.rpc(
        'get_paperless_operations_report',
        params: {
          'p_store_id': widget.storeId,
          'p_from': range.startUtc.toIso8601String(),
          'p_to': range.endExclusiveUtc.toIso8601String(),
        },
      );
      final report = _PaperlessReport.fromJson(
        Map<String, dynamic>.from(raw as Map),
      );
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
    return Container(
      key: const Key('paperless_operations_dashboard'),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  color: PosColors.accentMuted,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: const Icon(
                  Icons.query_stats_rounded,
                  color: PosColors.accent,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      copy.title,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    Text(
                      copy.subtitle,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: PosColors.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: copy.refresh,
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh_rounded),
              ),
            ],
          ),
          const SizedBox(height: 14),
          if (_loading)
            const SizedBox(
              height: 180,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (_error != null)
            _PaperlessMessage(
              icon: Icons.info_outline_rounded,
              message: copy.unavailable,
              action: TextButton(onPressed: _load, child: Text(copy.retry)),
            )
          else if ((_report?.orderCount ?? 0) == 0)
            _PaperlessMessage(
              icon: Icons.insights_outlined,
              message: copy.noData,
            )
          else
            _PaperlessDashboardBody(report: _report!, copy: copy),
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
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            _PaperlessMetric(
              label: copy.orders,
              value: '${report.completedOrderCount}/${report.orderCount}',
              helper: copy.completed,
              color: PosColors.accent,
            ),
            _PaperlessMetric(
              label: copy.averageTotal,
              value: _duration(report.averageTotalSeconds),
              helper: copy.orderToTable,
              color: PosColors.success,
            ),
            _PaperlessMetric(
              label: copy.p90Total,
              value: _duration(report.p90TotalSeconds),
              helper: copy.slowTenPercent,
              color: PosColors.warning,
            ),
            _PaperlessMetric(
              label: copy.bottleneck,
              value: copy.station(report.bottleneckStation),
              helper: copy.highestP90,
              color: PosColors.danger,
            ),
          ],
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final stationCards = report.stations
                .map(
                  (station) => _PaperlessStationCard(
                    station: station,
                    copy: copy,
                    bottleneck: station.station == report.bottleneckStation,
                  ),
                )
                .toList(growable: false);
            if (constraints.maxWidth < 760) {
              return Column(
                children: [
                  for (final card in stationCards) ...[
                    card,
                    if (card != stationCards.last) const SizedBox(height: 8),
                  ],
                ],
              );
            }
            return Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var index = 0; index < stationCards.length; index++) ...[
                  Expanded(child: stationCards[index]),
                  if (index < stationCards.length - 1) const SizedBox(width: 8),
                ],
              ],
            );
          },
        ),
        if (report.menuKitchenTimes.isNotEmpty) ...[
          const SizedBox(height: 14),
          Text(
            copy.slowMenus,
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w900),
          ),
          const SizedBox(height: 6),
          for (final menu in report.menuKitchenTimes.take(5))
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      menu.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '${copy.average} ${_duration(menu.averageSeconds)} · '
                    'P90 ${_duration(menu.p90Seconds)} · n=${menu.sampleCount}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: PosColors.textSecondary,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ],
    );
  }
}

class _PaperlessMetric extends StatelessWidget {
  const _PaperlessMetric({
    required this.label,
    required this.value,
    required this.helper,
    required this.color,
  });

  final String label;
  final String value;
  final String helper;
  final Color color;

  @override
  Widget build(BuildContext context) => Container(
    width: 210,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: PosSurfaceRole.background.fill,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: PosColors.border),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        const SizedBox(height: 2),
        Text(
          value,
          style: Theme.of(context).textTheme.titleLarge?.copyWith(
            color: color,
            fontWeight: FontWeight.w900,
          ),
        ),
        Text(
          helper,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
        ),
      ],
    ),
  );
}

class _PaperlessStationCard extends StatelessWidget {
  const _PaperlessStationCard({
    required this.station,
    required this.copy,
    required this.bottleneck,
  });

  final _StationMetric station;
  final _PaperlessCopy copy;
  final bool bottleneck;

  @override
  Widget build(BuildContext context) => Container(
    key: ValueKey('paperless_station_${station.station}'),
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: bottleneck ? const Color(0xFFFFF7ED) : PosColors.surface,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(
        color: bottleneck ? PosColors.warning : PosColors.border,
      ),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                copy.station(station.station),
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            if (bottleneck)
              Icon(Icons.warning_amber_rounded, color: PosColors.warning),
          ],
        ),
        const SizedBox(height: 6),
        Text('${copy.p50} ${_duration(station.p50Seconds)}'),
        Text('${copy.p90} ${_duration(station.p90Seconds)}'),
        Text('${copy.backlog} ${station.backlogQuantity}'),
        Text(
          'n=${station.sampleCount}',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
        ),
      ],
    ),
  );
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
    required this.averageTotalSeconds,
    required this.p90TotalSeconds,
    required this.bottleneckStation,
    required this.stations,
    required this.menuKitchenTimes,
  });

  final int orderCount;
  final int completedOrderCount;
  final int averageTotalSeconds;
  final int p90TotalSeconds;
  final String bottleneckStation;
  final List<_StationMetric> stations;
  final List<_MenuMetric> menuKitchenTimes;

  factory _PaperlessReport.fromJson(Map<String, dynamic> json) =>
      _PaperlessReport(
        orderCount: _int(json['order_count']),
        completedOrderCount: _int(json['completed_order_count']),
        averageTotalSeconds: _int(json['average_total_seconds']),
        p90TotalSeconds: _int(json['p90_total_seconds']),
        bottleneckStation: json['bottleneck_station']?.toString() ?? 'none',
        stations: _maps(
          json['stations'],
        ).map(_StationMetric.fromJson).toList(growable: false),
        menuKitchenTimes: _maps(
          json['menu_kitchen_times'],
        ).map(_MenuMetric.fromJson).toList(growable: false),
      );
}

class _StationMetric {
  const _StationMetric({
    required this.station,
    required this.sampleCount,
    required this.p50Seconds,
    required this.p90Seconds,
    required this.backlogQuantity,
  });

  final String station;
  final int sampleCount;
  final int p50Seconds;
  final int p90Seconds;
  final int backlogQuantity;

  factory _StationMetric.fromJson(Map<String, dynamic> json) => _StationMetric(
    station: json['station']?.toString() ?? 'none',
    sampleCount: _int(json['sample_count']),
    p50Seconds: _int(json['p50_seconds']),
    p90Seconds: _int(json['p90_seconds']),
    backlogQuantity: _int(json['backlog_quantity']),
  );
}

class _MenuMetric {
  const _MenuMetric({
    required this.name,
    required this.sampleCount,
    required this.averageSeconds,
    required this.p90Seconds,
  });

  final String name;
  final int sampleCount;
  final int averageSeconds;
  final int p90Seconds;

  factory _MenuMetric.fromJson(Map<String, dynamic> json) => _MenuMetric(
    name: json['name']?.toString() ?? 'Menu',
    sampleCount: _int(json['sample_count']),
    averageSeconds: _int(json['average_seconds']),
    p90Seconds: _int(json['p90_seconds']),
  );
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
    '주방·트레이·층별 처리시간과 현재 병목을 주문 이벤트로 계산합니다.',
    'Thời gian bếp, khay, tầng và điểm nghẽn được tính từ sự kiện đơn hàng.',
    'Station times and bottlenecks calculated from order events.',
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
  String get orders => pick('완료 주문', 'Đơn hoàn tất', 'Completed orders');
  String get completed => pick('완료/전체', 'Hoàn tất/tổng', 'completed / total');
  String get averageTotal => pick('평균 총 처리', 'TB toàn trình', 'Average total');
  String get orderToTable => pick('접수부터 테이블', 'Nhận đến bàn', 'order to table');
  String get p90Total => pick('P90 총 처리', 'P90 toàn trình', 'P90 total');
  String get slowTenPercent =>
      pick('느린 10% 기준', 'Nhóm chậm 10%', 'slowest 10%');
  String get bottleneck => pick('현재 병목', 'Điểm nghẽn', 'Bottleneck');
  String get highestP90 =>
      pick('P90 최장 구간', 'Chặng P90 dài nhất', 'highest P90 stage');
  String get p50 => 'P50';
  String get p90 => 'P90';
  String get backlog => pick('현재 대기', 'Đang chờ', 'Current backlog');
  String get slowMenus =>
      pick('조리시간이 긴 메뉴', 'Món có thời gian bếp lâu', 'Slowest kitchen items');
  String get average => pick('평균', 'TB', 'Avg');
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

String _duration(int seconds) {
  if (seconds <= 0) return '—';
  if (seconds < 60) return '${seconds}s';
  final minutes = seconds ~/ 60;
  final remainder = seconds % 60;
  return remainder == 0 ? '${minutes}m' : '${minutes}m ${remainder}s';
}
