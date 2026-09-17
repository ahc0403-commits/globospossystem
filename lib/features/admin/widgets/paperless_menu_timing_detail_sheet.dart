import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/ui/pos_design_tokens.dart';
import '../../../main.dart';
import '../../report/report_provider.dart';

typedef PaperlessMenuTimingDetailLoader =
    Future<Map<String, dynamic>> Function({
      required String menuKey,
      String? floorLabel,
      num? afterFloorSeconds,
      String? afterSampleKey,
    });

class PaperlessMenuTimingOverview {
  const PaperlessMenuTimingOverview({
    required this.menuKey,
    required this.menuName,
    required this.sampleCount,
    required this.kitchenAverageSeconds,
    required this.trayAverageSeconds,
    required this.floorAverageSeconds,
    required this.operationAverageSeconds,
  });

  final String menuKey;
  final String menuName;
  final int sampleCount;
  final int? kitchenAverageSeconds;
  final int? trayAverageSeconds;
  final int? floorAverageSeconds;
  final int operationAverageSeconds;
}

Future<void> showPaperlessMenuTimingDetailSheet({
  required BuildContext context,
  required String storeId,
  required DateTime startDate,
  required DateTime endDate,
  required PaperlessMenuTimingOverview overview,
  PaperlessMenuTimingDetailLoader? loader,
}) {
  final width = MediaQuery.sizeOf(context).width;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    backgroundColor: Colors.transparent,
    builder: (context) => Align(
      alignment: Alignment.bottomCenter,
      child: FractionallySizedBox(
        heightFactor: 0.9,
        widthFactor: width >= 1200 ? 0.82 : 1,
        child: Material(
          color: PosColors.surface,
          borderRadius: const BorderRadius.vertical(top: Radius.circular(22)),
          clipBehavior: Clip.antiAlias,
          child: PaperlessMenuTimingDetailSheet(
            storeId: storeId,
            startDate: startDate,
            endDate: endDate,
            overview: overview,
            loader: loader,
          ),
        ),
      ),
    ),
  );
}

class PaperlessMenuTimingDetailSheet extends StatefulWidget {
  const PaperlessMenuTimingDetailSheet({
    super.key,
    required this.storeId,
    required this.startDate,
    required this.endDate,
    required this.overview,
    this.loader,
  });

  final String storeId;
  final DateTime startDate;
  final DateTime endDate;
  final PaperlessMenuTimingOverview overview;
  final PaperlessMenuTimingDetailLoader? loader;

  @override
  State<PaperlessMenuTimingDetailSheet> createState() =>
      _PaperlessMenuTimingDetailSheetState();
}

class _PaperlessMenuTimingDetailSheetState
    extends State<PaperlessMenuTimingDetailSheet> {
  List<PaperlessFloorTimingSummary> _floorSummaries = const [];
  List<PaperlessMenuTimingSample> _samples = const [];
  String? _selectedFloor;
  num? _nextFloorSeconds;
  String? _nextSampleKey;
  int _totalCount = 0;
  bool _hasMore = false;
  bool _loading = true;
  bool _loadingMore = false;
  Object? _error;
  int _requestVersion = 0;

  @override
  void initState() {
    super.initState();
    _load(reset: true);
  }

  Future<Map<String, dynamic>> _fetch({
    required String? floorLabel,
    required num? afterFloorSeconds,
    required String? afterSampleKey,
  }) async {
    if (widget.loader case final loader?) {
      return loader(
        menuKey: widget.overview.menuKey,
        floorLabel: floorLabel,
        afterFloorSeconds: afterFloorSeconds,
        afterSampleKey: afterSampleKey,
      );
    }
    final range = reportUtcRange(widget.startDate, widget.endDate);
    final response = await supabase.rpc(
      'get_paperless_menu_timing_detail',
      params: {
        'p_store_id': widget.storeId,
        'p_from': range.startUtc.toIso8601String(),
        'p_to': range.endExclusiveUtc.toIso8601String(),
        'p_menu_key': widget.overview.menuKey,
        'p_floor_label': floorLabel,
        'p_limit': 50,
        'p_after_floor_seconds': afterFloorSeconds,
        'p_after_sample_key': afterSampleKey,
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<void> _load({required bool reset}) async {
    if (!reset && (!_hasMore || _loadingMore)) return;
    final requestVersion = ++_requestVersion;
    setState(() {
      _error = null;
      if (reset) {
        _loading = true;
        _samples = const [];
        _nextFloorSeconds = null;
        _nextSampleKey = null;
      } else {
        _loadingMore = true;
      }
    });
    try {
      final raw = await _fetch(
        floorLabel: _selectedFloor,
        afterFloorSeconds: reset ? null : _nextFloorSeconds,
        afterSampleKey: reset ? null : _nextSampleKey,
      );
      final page = PaperlessMenuTimingDetailPage.fromJson(raw);
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() {
        _floorSummaries = page.floorSummaries;
        _samples = reset ? page.samples : [..._samples, ...page.samples];
        _totalCount = page.totalCount;
        _hasMore = page.hasMore;
        _nextFloorSeconds = page.nextFloorSeconds;
        _nextSampleKey = page.nextSampleKey;
      });
    } catch (error) {
      if (!mounted || requestVersion != _requestVersion) return;
      setState(() => _error = error);
    } finally {
      if (mounted && requestVersion == _requestVersion) {
        setState(() {
          _loading = false;
          _loadingMore = false;
        });
      }
    }
  }

  void _selectFloor(String? floorLabel) {
    if (_selectedFloor == floorLabel) return;
    setState(() => _selectedFloor = floorLabel);
    _load(reset: true);
  }

  @override
  Widget build(BuildContext context) {
    final copy = _TimingDetailCopy.of(context);
    return Column(
      key: const Key('paperless_menu_timing_detail_sheet'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 10, 10),
          child: Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      copy.title,
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      widget.overview.menuName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: PosColors.textSecondary,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                tooltip: copy.close,
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.close_rounded),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Expanded(child: _buildBody(copy)),
      ],
    );
  }

  Widget _buildBody(_TimingDetailCopy copy) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.error_outline_rounded, size: 38),
              const SizedBox(height: 10),
              Text(copy.unavailable, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('paperless_menu_detail_retry'),
                onPressed: () => _load(reset: true),
                child: Text(copy.retry),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      key: const Key('paperless_menu_timing_detail_scroll'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 28),
      children: [
        _OverviewSection(overview: widget.overview, copy: copy),
        const SizedBox(height: 20),
        _SectionTitle(title: copy.floorComparison, helper: copy.floorHelper),
        const SizedBox(height: 10),
        _FloorFilter(
          summaries: _floorSummaries,
          selectedFloor: _selectedFloor,
          copy: copy,
          onSelected: _selectFloor,
        ),
        const SizedBox(height: 20),
        _SectionTitle(
          title: copy.sampleDetails,
          helper: copy.sampleCount(_totalCount),
        ),
        const SizedBox(height: 10),
        if (_samples.isEmpty)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 34),
            child: Text(
              copy.noSamples,
              textAlign: TextAlign.center,
              style: Theme.of(
                context,
              ).textTheme.bodyMedium?.copyWith(color: PosColors.textSecondary),
            ),
          )
        else
          ..._samples.map(
            (sample) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _SampleCard(sample: sample, copy: copy),
            ),
          ),
        if (_hasMore)
          Align(
            child: OutlinedButton.icon(
              key: const Key('paperless_menu_detail_load_more'),
              onPressed: _loadingMore ? null : () => _load(reset: false),
              icon: _loadingMore
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.expand_more_rounded),
              label: Text(copy.loadMore),
            ),
          ),
      ],
    );
  }
}

class _OverviewSection extends StatelessWidget {
  const _OverviewSection({required this.overview, required this.copy});

  final PaperlessMenuTimingOverview overview;
  final _TimingDetailCopy copy;

  @override
  Widget build(BuildContext context) {
    final metrics = [
      (copy.kitchen, overview.kitchenAverageSeconds, PosColors.warning),
      (copy.tray, overview.trayAverageSeconds, PosColors.info),
      (copy.floor, overview.floorAverageSeconds, PosColors.success),
      (copy.total, overview.operationAverageSeconds, PosColors.textPrimary),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _SectionTitle(
          title: copy.summary,
          helper: copy.sampleCount(overview.sampleCount),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final metric in metrics)
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: PosColors.panelMuted,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: PosColors.border),
                ),
                child: Text.rich(
                  TextSpan(
                    children: [
                      TextSpan(
                        text: '${metric.$1}  ',
                        style: const TextStyle(color: PosColors.textSecondary),
                      ),
                      TextSpan(
                        text: copy.duration(metric.$2),
                        style: TextStyle(
                          color: metric.$3,
                          fontWeight: FontWeight.w900,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
      ],
    );
  }
}

class _FloorFilter extends StatelessWidget {
  const _FloorFilter({
    required this.summaries,
    required this.selectedFloor,
    required this.copy,
    required this.onSelected,
  });

  final List<PaperlessFloorTimingSummary> summaries;
  final String? selectedFloor;
  final _TimingDetailCopy copy;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    if (summaries.isEmpty) {
      return Text(
        copy.noFloorData,
        style: Theme.of(
          context,
        ).textTheme.bodyMedium?.copyWith(color: PosColors.textSecondary),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ChoiceChip(
          key: const Key('paperless_menu_detail_floor_all'),
          selected: selectedFloor == null,
          label: Text(copy.allFloors),
          onSelected: (_) => onSelected(null),
        ),
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            const spacing = 10.0;
            final width = constraints.maxWidth >= 720
                ? (constraints.maxWidth - spacing) / 2
                : constraints.maxWidth;
            return Wrap(
              spacing: spacing,
              runSpacing: spacing,
              children: [
                for (final summary in summaries)
                  SizedBox(
                    width: width,
                    child: _FloorSummaryCard(
                      summary: summary,
                      selected: selectedFloor == summary.physicalFloorLabel,
                      copy: copy,
                      onTap: () => onSelected(summary.physicalFloorLabel),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _FloorSummaryCard extends StatelessWidget {
  const _FloorSummaryCard({
    required this.summary,
    required this.selected,
    required this.copy,
    required this.onTap,
  });

  final PaperlessFloorTimingSummary summary;
  final bool selected;
  final _TimingDetailCopy copy;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      key: Key('paperless_menu_detail_floor_${summary.physicalFloorLabel}'),
      color: selected ? PosColors.infoMuted : PosColors.panelMuted,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(
          color: selected ? PosColors.info : PosColors.border,
          width: selected ? 1.5 : 1,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      summary.physicalFloorLabel,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                  Text(
                    copy.sampleCount(summary.sampleCount),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  _InlineMetric(
                    label: copy.average,
                    value: copy.duration(summary.averageFloorSeconds),
                  ),
                  _InlineMetric(
                    label: copy.p90,
                    value: copy.duration(summary.p90FloorSeconds),
                  ),
                  _InlineMetric(
                    label: copy.maximum,
                    value: copy.duration(summary.maxFloorSeconds),
                  ),
                ],
              ),
              if (summary.inferredSampleCount > 0) ...[
                const SizedBox(height: 7),
                Text(
                  copy.inferredCount(summary.inferredSampleCount),
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: PosColors.warning,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _InlineMetric extends StatelessWidget {
  const _InlineMetric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Text.rich(
    TextSpan(
      children: [
        TextSpan(
          text: '$label ',
          style: const TextStyle(color: PosColors.textSecondary),
        ),
        TextSpan(
          text: value,
          style: const TextStyle(fontWeight: FontWeight.w800),
        ),
      ],
    ),
  );
}

class _SampleCard extends StatelessWidget {
  const _SampleCard({required this.sample, required this.copy});

  final PaperlessMenuTimingSample sample;
  final _TimingDetailCopy copy;

  @override
  Widget build(BuildContext context) {
    final routeDiffers =
        sample.routingFloorLabel.isNotEmpty &&
        sample.routingFloorLabel != sample.physicalFloorLabel;
    final subtitleParts = <String>[
      '${copy.table} ${sample.tableNumber}',
      '${copy.queue} #${sample.queueNo}',
      copy.route(sample.routeType),
      if (routeDiffers) '${copy.routingStation} ${sample.routingFloorLabel}',
      if (sample.physicalFloorInferred) copy.inferred,
    ];
    return Card(
      margin: EdgeInsets.zero,
      child: ExpansionTile(
        key: Key('paperless_menu_detail_sample_${sample.sampleKey}'),
        tilePadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
        childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
        title: Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: PosColors.successMuted,
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                sample.physicalFloorLabel,
                style: const TextStyle(
                  color: PosColors.success,
                  fontWeight: FontWeight.w900,
                ),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${copy.floor} ${copy.duration(sample.floorSeconds)}',
                style: const TextStyle(fontWeight: FontWeight.w900),
              ),
            ),
            Text(
              _shortId(sample.orderId),
              style: Theme.of(
                context,
              ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
            ),
          ],
        ),
        subtitle: Text(subtitleParts.join(' · ')),
        children: [
          const Divider(height: 18),
          _DetailRow(label: copy.quantity, value: '${sample.orderedQuantity}'),
          _DetailRow(label: copy.received, value: copy.time(sample.receivedAt)),
          _DetailRow(
            label: copy.kitchenDone,
            value: copy.time(sample.kitchenDoneAt),
          ),
          _DetailRow(
            label: copy.trayDispatched,
            value: copy.time(sample.trayDispatchedAt),
          ),
          _DetailRow(
            label: copy.floorServed,
            value: copy.time(sample.floorServedAt),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 12,
            runSpacing: 6,
            children: [
              _InlineMetric(
                label: copy.kitchen,
                value: copy.duration(sample.kitchenSeconds),
              ),
              _InlineMetric(
                label: copy.tray,
                value: copy.duration(sample.traySeconds),
              ),
              _InlineMetric(
                label: copy.floor,
                value: copy.duration(sample.floorSeconds),
              ),
              _InlineMetric(
                label: copy.total,
                value: copy.duration(sample.operationSeconds),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  const _DetailRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 3),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 126,
          child: Text(
            label,
            style: Theme.of(
              context,
            ).textTheme.bodySmall?.copyWith(color: PosColors.textSecondary),
          ),
        ),
        Expanded(child: Text(value)),
      ],
    ),
  );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, required this.helper});

  final String title;
  final String helper;

  @override
  Widget build(BuildContext context) => Wrap(
    spacing: 8,
    runSpacing: 2,
    crossAxisAlignment: WrapCrossAlignment.center,
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

class PaperlessMenuTimingDetailPage {
  const PaperlessMenuTimingDetailPage({
    required this.floorSummaries,
    required this.samples,
    required this.totalCount,
    required this.hasMore,
    required this.nextFloorSeconds,
    required this.nextSampleKey,
  });

  final List<PaperlessFloorTimingSummary> floorSummaries;
  final List<PaperlessMenuTimingSample> samples;
  final int totalCount;
  final bool hasMore;
  final num? nextFloorSeconds;
  final String? nextSampleKey;

  factory PaperlessMenuTimingDetailPage.fromJson(Map<String, dynamic> json) {
    final cursor = _map(json['next_cursor']);
    return PaperlessMenuTimingDetailPage(
      floorSummaries: _maps(
        json['floor_summaries'],
      ).map(PaperlessFloorTimingSummary.fromJson).toList(growable: false),
      samples: _maps(
        json['samples'],
      ).map(PaperlessMenuTimingSample.fromJson).toList(growable: false),
      totalCount: _int(json['total_count']),
      hasMore: json['has_more'] == true,
      nextFloorSeconds: _numOrNull(cursor['floor_seconds']),
      nextSampleKey: cursor['sample_key']?.toString(),
    );
  }
}

class PaperlessFloorTimingSummary {
  const PaperlessFloorTimingSummary({
    required this.physicalFloorLabel,
    required this.sampleCount,
    required this.inferredSampleCount,
    required this.averageFloorSeconds,
    required this.p90FloorSeconds,
    required this.maxFloorSeconds,
  });

  final String physicalFloorLabel;
  final int sampleCount;
  final int inferredSampleCount;
  final int averageFloorSeconds;
  final int p90FloorSeconds;
  final int maxFloorSeconds;

  factory PaperlessFloorTimingSummary.fromJson(Map<String, dynamic> json) =>
      PaperlessFloorTimingSummary(
        physicalFloorLabel:
            json['physical_floor_label']?.toString() ?? 'UNKNOWN',
        sampleCount: _int(json['sample_count']),
        inferredSampleCount: _int(json['inferred_sample_count']),
        averageFloorSeconds: _int(json['average_floor_seconds']),
        p90FloorSeconds: _int(json['p90_floor_seconds']),
        maxFloorSeconds: _int(json['max_floor_seconds']),
      );
}

class PaperlessMenuTimingSample {
  const PaperlessMenuTimingSample({
    required this.sampleKey,
    required this.orderId,
    required this.queueNo,
    required this.tableNumber,
    required this.physicalFloorLabel,
    required this.routingFloorLabel,
    required this.physicalFloorInferred,
    required this.routeType,
    required this.orderedQuantity,
    required this.receivedAt,
    required this.kitchenDoneAt,
    required this.trayDispatchedAt,
    required this.floorServedAt,
    required this.kitchenSeconds,
    required this.traySeconds,
    required this.floorSeconds,
    required this.operationSeconds,
  });

  final String sampleKey;
  final String orderId;
  final int queueNo;
  final String tableNumber;
  final String physicalFloorLabel;
  final String routingFloorLabel;
  final bool physicalFloorInferred;
  final String routeType;
  final int orderedQuantity;
  final DateTime? receivedAt;
  final DateTime? kitchenDoneAt;
  final DateTime? trayDispatchedAt;
  final DateTime? floorServedAt;
  final int? kitchenSeconds;
  final int? traySeconds;
  final int floorSeconds;
  final int operationSeconds;

  factory PaperlessMenuTimingSample.fromJson(Map<String, dynamic> json) =>
      PaperlessMenuTimingSample(
        sampleKey: json['sample_key']?.toString() ?? '',
        orderId: json['order_id']?.toString() ?? '',
        queueNo: _int(json['queue_no']),
        tableNumber: json['table_number']?.toString() ?? '-',
        physicalFloorLabel:
            json['physical_floor_label']?.toString() ?? 'UNKNOWN',
        routingFloorLabel: json['routing_floor_label']?.toString() ?? '',
        physicalFloorInferred: json['physical_floor_inferred'] == true,
        routeType: json['route_type']?.toString() ?? 'kitchen_tray_floor',
        orderedQuantity: _int(json['ordered_quantity']),
        receivedAt: _dateTime(json['received_at']),
        kitchenDoneAt: _dateTime(json['kitchen_done_at']),
        trayDispatchedAt: _dateTime(json['tray_dispatched_at']),
        floorServedAt: _dateTime(json['floor_served_at']),
        kitchenSeconds: _nullableInt(json['kitchen_seconds']),
        traySeconds: _nullableInt(json['tray_seconds']),
        floorSeconds: _int(json['floor_seconds']),
        operationSeconds: _int(json['operation_seconds']),
      );
}

class _TimingDetailCopy {
  const _TimingDetailCopy(this.code);

  final String code;

  static _TimingDetailCopy of(BuildContext context) =>
      _TimingDetailCopy(Localizations.localeOf(context).languageCode);

  String pick(String ko, String vi, String en) => switch (code) {
    'vi' => vi,
    'en' => en,
    _ => ko,
  };

  String get title => pick(
    '메뉴 제공시간 상세',
    'Chi tiết thời gian phục vụ món',
    'Menu service-time details',
  );
  String get summary => pick('메뉴 요약', 'Tóm tắt món', 'Menu summary');
  String get floorComparison =>
      pick('층별 비교', 'So sánh theo tầng', 'Floor comparison');
  String get floorHelper => pick(
    '층 서빙 평균이 긴 순 · 실제 테이블 층 기준',
    'TB phục vụ tầng lâu nhất trước · theo tầng bàn thực tế',
    'Slowest floor average first · based on the physical table floor',
  );
  String get sampleDetails =>
      pick('개별 표본', 'Mẫu chi tiết', 'Individual samples');
  String get allFloors => pick('전체 층', 'Tất cả tầng', 'All floors');
  String get noFloorData => pick(
    '층 서빙이 완료된 표본이 없습니다.',
    'Không có mẫu phục vụ tầng đã hoàn tất.',
    'No completed floor-service samples.',
  );
  String get noSamples => pick(
    '선택한 층에 상세 표본이 없습니다.',
    'Không có mẫu chi tiết cho tầng đã chọn.',
    'No detail samples for the selected floor.',
  );
  String get unavailable => pick(
    '상세 내역을 불러오지 못했습니다.',
    'Không thể tải chi tiết.',
    'The detail could not be loaded.',
  );
  String get retry => pick('다시 시도', 'Thử lại', 'Retry');
  String get close => pick('닫기', 'Đóng', 'Close');
  String get loadMore => pick('더 보기', 'Xem thêm', 'Load more');
  String get average => pick('평균', 'TB', 'Avg');
  String get p90 => 'P90';
  String get maximum => pick('최대', 'Tối đa', 'Max');
  String get kitchen => pick('주방', 'Bếp', 'Kitchen');
  String get tray => pick('트레이', 'Khay', 'Tray');
  String get floor => pick('층 서빙', 'Tầng', 'Floor');
  String get total => pick('운영 합계', 'Tổng', 'Total');
  String get table => pick('테이블', 'Bàn', 'Table');
  String get queue => pick('대기번호', 'Số chờ', 'Queue');
  String get routingStation =>
      pick('담당 스테이션', 'Trạm phụ trách', 'Routing station');
  String get inferred => pick('과거 층 추정', 'Tầng cũ ước tính', 'Inferred floor');
  String get quantity => pick('수량', 'Số lượng', 'Quantity');
  String get received => pick('메뉴 접수', 'Nhận món', 'Menu received');
  String get kitchenDone => pick('주방 완료', 'Bếp xong', 'Kitchen done');
  String get trayDispatched =>
      pick('트레이 출발', 'Khay xuất phát', 'Tray dispatched');
  String get floorServed => pick('서빙 완료', 'Phục vụ xong', 'Service completed');

  String sampleCount(int count) =>
      pick('표본 $count건', '$count mẫu', '$count samples');
  String inferredCount(int count) => pick(
    '과거 데이터 추정 $count건',
    '$count mẫu lịch sử ước tính',
    '$count historical samples inferred',
  );
  String route(String value) => switch (value) {
    'floor_direct' => pick('직접 전달', 'Giao trực tiếp', 'Direct floor'),
    'combo_component' => pick('콤보 구성품', 'Món combo', 'Combo component'),
    _ => pick('주방→트레이→층', 'Bếp→khay→tầng', 'Kitchen→tray→floor'),
  };
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

  String time(DateTime? value) {
    if (value == null) return '—';
    return DateFormat('dd/MM HH:mm:ss').format(toHoChiMinhBusinessTime(value));
  }
}

String _shortId(String value) =>
    value.length <= 8 ? value : value.substring(0, 8);

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false)
    : const [];

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

int _int(Object? value) => switch (value) {
  int number => number,
  num number => number.round(),
  String text => num.tryParse(text)?.round() ?? 0,
  _ => 0,
};

int? _nullableInt(Object? value) => value == null ? null : _int(value);

num? _numOrNull(Object? value) => switch (value) {
  num number => number,
  String text => num.tryParse(text),
  _ => null,
};

DateTime? _dateTime(Object? value) =>
    value == null ? null : DateTime.tryParse(value.toString());
