import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/i18n/menu_localization.dart';
import '../../../core/ui/pos_design_tokens.dart';

typedef PaperlessTimingTrendLoader =
    Future<Map<String, dynamic>> Function({
      required String storeId,
      required DateTime startDate,
      required DateTime endDate,
    });

enum PaperlessTimingChange { improved, worsened, stable, insufficient }

class PaperlessTimingTrends {
  PaperlessTimingTrends.fromJson(Map<String, dynamic> json)
    : baselineFrom = DateTime.parse(json['baseline_from'] as String),
      baselineTo = DateTime.parse(json['baseline_to'] as String),
      buckets = _rows(
        json['buckets'],
      ).map(PaperlessTimingBucket.fromJson).toList(),
      menus = _rows(json['menus']).map(PaperlessTimingMenu.fromJson).toList();

  final DateTime baselineFrom;
  final DateTime baselineTo;
  final List<PaperlessTimingBucket> buckets;
  final List<PaperlessTimingMenu> menus;

  static Iterable<Map<String, dynamic>> _rows(dynamic value) =>
      (value as List? ?? const []).whereType<Map>().map(
        (row) => Map<String, dynamic>.from(row),
      );
}

class PaperlessTimingBucket {
  PaperlessTimingBucket.fromJson(Map<String, dynamic> json)
    : index = (json['index'] as num).toInt(),
      from = DateTime.parse(json['from_date'] as String),
      to = DateTime.parse(json['to_date'] as String);

  final int index;
  final DateTime from;
  final DateTime to;

  String get label {
    final format = DateFormat('MM/dd');
    return from == to
        ? format.format(from)
        : '${format.format(from)}–${format.format(to)}';
  }
}

class PaperlessTimingPoint {
  PaperlessTimingPoint.fromJson(Map<String, dynamic> json)
    : bucketIndex = (json['bucket_index'] as num).toInt(),
      averageSeconds = (json['average_seconds'] as num).toInt(),
      sampleCount = (json['sample_count'] as num).toInt();

  final int bucketIndex;
  final int averageSeconds;
  final int sampleCount;
}

class PaperlessTimingMenu {
  PaperlessTimingMenu.fromJson(Map<String, dynamic> json)
    : menuKey = json['menu_key'] as String,
      names = {
        'name': json['name'],
        'name_ko': json['name_ko'],
        'name_vi': json['name_vi'],
        'name_en': json['name_en'],
      },
      baselineSeconds = (json['baseline_average_seconds'] as num?)?.toInt(),
      currentSeconds = (json['current_average_seconds'] as num?)?.toInt(),
      baselineCount = (json['baseline_sample_count'] as num?)?.toInt() ?? 0,
      currentCount = (json['current_sample_count'] as num?)?.toInt() ?? 0,
      points = {
        for (final point in PaperlessTimingTrends._rows(
          json['points'],
        ).map(PaperlessTimingPoint.fromJson))
          point.bucketIndex: point,
      };

  static const minimumSamples = 5;
  static const stableSeconds = 30;

  final String menuKey;
  final Map<String, dynamic> names;
  final int? baselineSeconds;
  final int? currentSeconds;
  final int baselineCount;
  final int currentCount;
  final Map<int, PaperlessTimingPoint> points;

  String name(String languageCode) => localizedMenuName(names, languageCode);

  int? get deltaSeconds => baselineSeconds == null || currentSeconds == null
      ? null
      : currentSeconds! - baselineSeconds!;

  PaperlessTimingChange get change {
    if (baselineCount < minimumSamples ||
        currentCount < minimumSamples ||
        deltaSeconds == null) {
      return PaperlessTimingChange.insufficient;
    }
    if (deltaSeconds!.abs() < stableSeconds) {
      return PaperlessTimingChange.stable;
    }
    return deltaSeconds! < 0
        ? PaperlessTimingChange.improved
        : PaperlessTimingChange.worsened;
  }
}

enum _TrendSort { worsened, improved, samples }

class PaperlessTimingTrendsSection extends StatefulWidget {
  const PaperlessTimingTrendsSection({
    super.key,
    required this.trends,
    this.unavailable = false,
    this.onMenuDetails,
  });

  final PaperlessTimingTrends? trends;
  final bool unavailable;
  final ValueChanged<String>? onMenuDetails;

  @override
  State<PaperlessTimingTrendsSection> createState() =>
      _PaperlessTimingTrendsSectionState();
}

class _PaperlessTimingTrendsSectionState
    extends State<PaperlessTimingTrendsSection> {
  _TrendSort _sort = _TrendSort.worsened;
  PaperlessTimingChange? _filter;
  String? _selectedMenu;
  int? _windowEnd;
  int _visibleRows = 20;

  @override
  void didUpdateWidget(covariant PaperlessTimingTrendsSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.trends != widget.trends) {
      _selectedMenu = null;
      _windowEnd = null;
      _visibleRows = 20;
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = _TrendCopy(Localizations.localeOf(context).languageCode);
    final trends = widget.trends;
    return Container(
      key: const Key('paperless_timing_trends'),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            copy.t(
              '메뉴별 기간 변화',
              'Menu timing over time',
              'Thời gian món theo kỳ',
            ),
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w900),
          ),
          if (trends == null || trends.menus.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 20),
              child: Text(
                widget.unavailable
                    ? copy.t(
                        '기간별 데이터를 불러오지 못했습니다. 새로고침해 주세요.',
                        'Could not load timing trends. Please refresh.',
                        'Không tải được xu hướng. Vui lòng làm mới.',
                      )
                    : copy.t(
                        '완료된 메뉴 제공 기록이 없습니다.',
                        'No completed menu service records.',
                        'Chưa có dữ liệu phục vụ món hoàn tất.',
                      ),
              ),
            )
          else ...[
            const SizedBox(height: 6),
            Text(
              '${copy.t('비교 기준', 'Fixed baseline', 'Kỳ gốc cố định')}: '
              '${DateFormat('yyyy.MM.dd').format(trends.baselineFrom)} – '
              '${DateFormat('yyyy.MM.dd').format(trends.baselineTo)}',
              key: const Key('paperless_trend_baseline'),
            ),
            Text(
              copy.t(
                '직전 동일 길이 기간의 평균과 비교 · 접수부터 제공 완료까지',
                'Mean time from receipt to service, compared with the preceding equal-length period',
                'Thời gian trung bình từ tiếp nhận đến phục vụ, so với kỳ liền trước cùng độ dài',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _summary(trends, copy),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                for (final sort in _TrendSort.values)
                  ChoiceChip(
                    key: Key('paperless_trend_sort_${sort.name}'),
                    label: Text(copy.sort(sort)),
                    selected: _sort == sort,
                    onSelected: (_) => setState(() {
                      _sort = sort;
                      _visibleRows = 20;
                    }),
                  ),
                Text(
                  copy.t(
                    '파랑 − 단축 · 주황 + 증가 · ±30초 미만 유지',
                    'Blue − faster · Orange + slower · Under ±30s unchanged',
                    'Xanh − nhanh hơn · Cam + chậm hơn · Dưới ±30 giây: ổn định',
                  ),
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ),
            Text(
              copy.t(
                '각 칸: 기준 대비 변화 / 실제 평균 · 색 농도는 ±5분에서 최대 · 5건 미만은 데이터 적음',
                'Cells: change / actual mean · Color saturates at ±5 min · Fewer than 5 samples: limited data',
                'Mỗi ô: thay đổi / trung bình thực tế · Màu đậm nhất ở ±5 phút · Dưới 5 mẫu: ít dữ liệu',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            LayoutBuilder(
              builder: (context, constraints) => _heatmap(
                trends,
                copy,
                constraints.maxWidth,
                MediaQuery.textScalerOf(context).scale(1),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _summary(PaperlessTimingTrends trends, _TrendCopy copy) {
    final comparable =
        trends.menus
            .where((menu) => menu.change != PaperlessTimingChange.insufficient)
            .toList()
          ..sort((a, b) => b.deltaSeconds!.compareTo(a.deltaSeconds!));
    final worst = comparable
        .where((menu) => menu.change == PaperlessTimingChange.worsened)
        .firstOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            FilterChip(
              key: const Key('paperless_trend_filter_all'),
              label: Text(copy.t('전체', 'All', 'Tất cả')),
              selected: _filter == null,
              onSelected: (_) => setState(() => _filter = null),
            ),
            for (final change in PaperlessTimingChange.values)
              FilterChip(
                key: Key('paperless_trend_filter_${change.name}'),
                label: Text(
                  '${copy.change(change)} ${trends.menus.where((menu) => menu.change == change).length}',
                ),
                selected: _filter == change,
                onSelected: (_) => setState(() {
                  _filter = _filter == change ? null : change;
                  _visibleRows = 20;
                }),
              ),
          ],
        ),
        if (worst != null)
          Text(
            '${copy.t('가장 많이 느려진 메뉴', 'Largest slowdown', 'Món chậm đi nhiều nhất')}: '
            '${worst.name(copy.code)} ${copy.delta(worst.deltaSeconds!)}',
            style: const TextStyle(
              color: Color(0xff9a4800),
              fontWeight: FontWeight.w700,
            ),
          ),
      ],
    );
  }

  Widget _heatmap(
    PaperlessTimingTrends trends,
    _TrendCopy copy,
    double width,
    double textScale,
  ) {
    final rows =
        trends.menus
            .where((menu) => _filter == null || menu.change == _filter)
            .toList()
          ..sort((a, b) {
            if (_sort == _TrendSort.samples) {
              final count = b.currentCount.compareTo(a.currentCount);
              return count != 0 ? count : a.menuKey.compareTo(b.menuKey);
            }
            final aDelta = a.deltaSeconds;
            final bDelta = b.deltaSeconds;
            final aLimited = a.change == PaperlessTimingChange.insufficient;
            final bLimited = b.change == PaperlessTimingChange.insufficient;
            if (aLimited != bLimited) return aLimited ? 1 : -1;
            if (aDelta == null || bDelta == null) {
              if (aDelta != bDelta) return aDelta == null ? 1 : -1;
            } else {
              final order = _sort == _TrendSort.improved
                  ? aDelta.compareTo(bDelta)
                  : bDelta.compareTo(aDelta);
              if (order != 0) return order;
            }
            return a.menuKey.compareTo(b.menuKey);
          });
    final columnCount = width < 600
        ? 4
        : width < 1000
        ? 6
        : 8;
    final end = (_windowEnd ?? trends.buckets.length)
        .clamp(
          math.min(columnCount, trends.buckets.length),
          trends.buckets.length,
        )
        .toInt();
    final start = math.max(0, end - columnCount);
    final buckets = trends.buckets.sublist(start, end);
    final mobile = width < 600;
    final nameWidth = mobile ? width : 210.0;
    final cellWidth = math.max(
      112.0 * math.min(textScale, 2),
      (width - nameWidth) / math.max(1, buckets.length),
    );
    Widget label(Widget child) => SizedBox(
      width: nameWidth,
      child: Padding(padding: const EdgeInsets.all(8), child: child),
    );
    Widget menuLabel(PaperlessTimingMenu menu) => TextButton(
      key: Key('paperless_trend_menu_${menu.menuKey}'),
      style: TextButton.styleFrom(
        alignment: Alignment.centerLeft,
        padding: EdgeInsets.zero,
        backgroundColor: _selectedMenu == menu.menuKey
            ? PosColors.infoMuted
            : null,
      ),
      onPressed: () => setState(() {
        _selectedMenu = _selectedMenu == menu.menuKey ? null : menu.menuKey;
      }),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            menu.name(copy.code),
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            '${copy.change(menu.change)} · ${copy.samples(menu.currentCount)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          Text(
            '${copy.t('기준', 'Baseline', 'Gốc')} ${copy.minutes(menu.baselineSeconds)}'
            ' · ${copy.samples(menu.baselineCount)}',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
    Widget gridRow(PaperlessTimingMenu menu) => mobile
        ? Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              menuLabel(menu),
              Wrap(
                children: [
                  for (final bucket in buckets)
                    SizedBox(
                      width: width / (textScale > 1.35 ? 2 : 4),
                      child: Column(
                        children: [
                          Text(bucket.label, textAlign: TextAlign.center),
                          _cell(menu, bucket, copy),
                        ],
                      ),
                    ),
                ],
              ),
              const Divider(height: 16),
            ],
          )
        : Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              label(menuLabel(menu)),
              for (final bucket in buckets)
                SizedBox(width: cellWidth, child: _cell(menu, bucket, copy)),
            ],
          );
    List<Widget> visibleRows() => [
      for (final menu in rows.take(_visibleRows)) ...[
        gridRow(menu),
        if (menu.menuKey == _selectedMenu)
          SizedBox(
            width: width,
            child: Padding(
              padding: const EdgeInsets.only(top: 12, bottom: 16),
              child: _detail(menu, trends, copy),
            ),
          ),
      ],
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              key: const Key('paperless_trend_previous'),
              tooltip: copy.t('이전 구간', 'Earlier periods', 'Kỳ trước'),
              onPressed: start == 0
                  ? null
                  : () => setState(() {
                      _windowEnd = math.max(columnCount, end - columnCount);
                    }),
              icon: const Icon(Icons.chevron_left),
            ),
            Expanded(
              child: Text(
                buckets.isEmpty
                    ? ''
                    : '${buckets.first.label} / ${buckets.last.label}',
                textAlign: TextAlign.center,
              ),
            ),
            IconButton(
              key: const Key('paperless_trend_next'),
              tooltip: copy.t('다음 구간', 'Later periods', 'Kỳ sau'),
              onPressed: end == trends.buckets.length
                  ? null
                  : () => setState(() {
                      _windowEnd = math.min(
                        trends.buckets.length,
                        end + columnCount,
                      );
                    }),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
        if (mobile)
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: visibleRows(),
          )
        else
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    label(
                      Text(
                        copy.t(
                          '메뉴 / 기준 평균',
                          'Menu / baseline mean',
                          'Món / trung bình gốc',
                        ),
                      ),
                    ),
                    for (final bucket in buckets)
                      SizedBox(
                        width: cellWidth,
                        child: Text(bucket.label, textAlign: TextAlign.center),
                      ),
                  ],
                ),
                ...visibleRows(),
              ],
            ),
          ),
        if (rows.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              copy.t(
                '해당 메뉴가 없습니다.',
                'No matching menus.',
                'Không có món phù hợp.',
              ),
            ),
          ),
        if (rows.length > _visibleRows)
          TextButton(
            key: const Key('paperless_trend_more'),
            onPressed: () => setState(() => _visibleRows += 20),
            child: Text(copy.t('메뉴 더 보기', 'Show more menus', 'Xem thêm món')),
          ),
      ],
    );
  }

  Widget _cell(
    PaperlessTimingMenu menu,
    PaperlessTimingBucket bucket,
    _TrendCopy copy,
  ) {
    final point = menu.points[bucket.index];
    final delta = point == null || menu.baselineSeconds == null
        ? null
        : point.averageSeconds - menu.baselineSeconds!;
    final color =
        delta == null || delta.abs() < PaperlessTimingMenu.stableSeconds
        ? const Color(0xff526477)
        : delta < 0
        ? const Color(0xff0b438e)
        : const Color(0xff753600);
    final tint =
        delta == null || delta.abs() < PaperlessTimingMenu.stableSeconds
        ? const Color(0xfff1f4f8)
        : Color.lerp(
            Colors.white,
            delta < 0 ? const Color(0xff8dbaf4) : const Color(0xfff1b36e),
            0.2 + 0.65 * (delta.abs() / 300).clamp(0, 1),
          )!;
    final limited =
        point != null && point.sampleCount < PaperlessTimingMenu.minimumSamples;
    final text = point == null
        ? copy.t('기록 없음', 'No samples', 'Không có mẫu')
        : delta == null
        ? copy.t('기준 없음', 'No baseline', 'Chưa có kỳ gốc')
        : copy.delta(delta);
    final description =
        '${menu.name(copy.code)}, ${bucket.label}, $text'
        '${point == null ? '' : ', ${copy.minutes(point.averageSeconds)}, ${copy.samples(point.sampleCount)}'}';
    return Padding(
      padding: const EdgeInsets.all(3),
      child: Semantics(
        label: description,
        button: true,
        child: Tooltip(
          message: description,
          child: Material(
            color: tint,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              key: Key('paperless_trend_cell_${menu.menuKey}_${bucket.index}'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => setState(() => _selectedMenu = menu.menuKey),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 10,
                ),
                child: Column(
                  children: [
                    Text(
                      text,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: color,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    if (point != null) ...[
                      Text(
                        copy.minutes(point.averageSeconds),
                        textAlign: TextAlign.center,
                      ),
                      Text(
                        '${copy.samples(point.sampleCount)}${limited ? ' · ${copy.t('적음', 'limited', 'ít')}' : ''}',
                        textAlign: TextAlign.center,
                        style: Theme.of(
                          context,
                        ).textTheme.bodySmall?.copyWith(color: color),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _detail(
    PaperlessTimingMenu menu,
    PaperlessTimingTrends trends,
    _TrendCopy copy,
  ) {
    final maxSeconds = [
      ...menu.points.values.map((point) => point.averageSeconds),
      if (menu.baselineSeconds != null) menu.baselineSeconds!,
      60,
    ].reduce(math.max);
    final maxMinutes = math
        .max(5, (maxSeconds / 60 * 1.15 / 5).ceil() * 5)
        .toDouble();
    final tickInterval = math.max(1, (maxMinutes / 5).ceil()).toDouble();
    return Column(
      key: Key('paperless_trend_detail_${menu.menuKey}'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 12,
          runSpacing: 4,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              menu.name(copy.code),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            Text(
              '${copy.t('이전', 'Previous', 'Trước')} ${copy.minutes(menu.baselineSeconds)} → '
              '${copy.t('현재', 'Current', 'Hiện tại')} ${copy.minutes(menu.currentSeconds)}',
            ),
            if (menu.deltaSeconds != null) Text(copy.delta(menu.deltaSeconds!)),
            if (widget.onMenuDetails != null && menu.currentCount > 0)
              TextButton.icon(
                onPressed: () => widget.onMenuDetails!(menu.menuKey),
                icon: const Icon(Icons.receipt_long_outlined, size: 18),
                label: Text(copy.t('주문 상세', 'Order details', 'Chi tiết đơn')),
              ),
          ],
        ),
        Text(
          copy.t(
            '실선: 구간별 평균 · 점선: 고정 비교 기준 · 단위: 분',
            'Solid: period mean · Dashed: fixed baseline · Unit: minutes',
            'Nét liền: trung bình từng kỳ · Nét đứt: kỳ gốc cố định · Đơn vị: phút',
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 210,
          child: LineChart(
            LineChartData(
              minX: 0,
              maxX: math.max(1, trends.buckets.length - 1).toDouble(),
              minY: 0,
              maxY: maxMinutes,
              borderData: FlBorderData(show: false),
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: tickInterval,
              ),
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
                    reservedSize: 42,
                    interval: tickInterval,
                  ),
                ),
                bottomTitles: AxisTitles(
                  sideTitles: SideTitles(
                    showTitles: true,
                    interval: math
                        .max(1, (trends.buckets.length / 3).ceil())
                        .toDouble(),
                    reservedSize: 32,
                    getTitlesWidget: (value, meta) {
                      final index = value.toInt();
                      if (index < 0 ||
                          index >= trends.buckets.length ||
                          value != index.toDouble()) {
                        return const SizedBox.shrink();
                      }
                      return Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          DateFormat(
                            'MM/dd',
                          ).format(trends.buckets[index].from),
                          style: const TextStyle(fontSize: 10),
                        ),
                      );
                    },
                  ),
                ),
              ),
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipItems: (spots) => spots.map((spot) {
                    final index = spot.x.toInt();
                    if (index < 0 || index >= trends.buckets.length) {
                      return null;
                    }
                    final bucket = trends.buckets[index];
                    final point = menu.points[bucket.index];
                    if (point == null) return null;
                    return LineTooltipItem(
                      '${bucket.label}\n${copy.minutes(point.averageSeconds)}\n${copy.samples(point.sampleCount)}',
                      const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w600,
                      ),
                    );
                  }).toList(),
                ),
              ),
              extraLinesData: ExtraLinesData(
                horizontalLines: [
                  if (menu.baselineSeconds != null)
                    HorizontalLine(
                      y: menu.baselineSeconds! / 60,
                      color: PosColors.textSecondary,
                      dashArray: [5, 4],
                    ),
                ],
              ),
              lineBarsData: [
                LineChartBarData(
                  color: const Color(0xff135bbb),
                  barWidth: 3,
                  isCurved: false,
                  dotData: const FlDotData(show: true),
                  spots: [
                    for (var index = 0; index < trends.buckets.length; index++)
                      menu.points[trends.buckets[index].index] == null
                          ? FlSpot.nullSpot
                          : FlSpot(
                              index.toDouble(),
                              menu
                                      .points[trends.buckets[index].index]!
                                      .averageSeconds /
                                  60,
                            ),
                  ],
                ),
              ],
            ),
            duration: Duration.zero,
          ),
        ),
      ],
    );
  }
}

class _TrendCopy {
  const _TrendCopy(this.code);
  final String code;

  String t(String ko, String en, String vi) => switch (code) {
    'en' => en,
    'vi' => vi,
    _ => ko,
  };

  String samples(int count) => t('$count건', '$count samples', '$count mẫu');
  String minutes(int? seconds) => seconds == null
      ? t('기록 없음', 'No samples', 'Không có mẫu')
      : '${(seconds / 60).toStringAsFixed(1)}${t('분', ' min', ' phút')}';
  String delta(int seconds) =>
      '${seconds < 0 ? '−' : '+'}${(seconds.abs() / 60).toStringAsFixed(1)}${t('분', ' min', ' phút')}';

  String change(PaperlessTimingChange value) => switch (value) {
    PaperlessTimingChange.improved => t('개선', 'Improved', 'Cải thiện'),
    PaperlessTimingChange.worsened => t('악화', 'Worsened', 'Chậm hơn'),
    PaperlessTimingChange.stable => t('유지', 'Unchanged', 'Ổn định'),
    PaperlessTimingChange.insufficient => t(
      '비교 데이터 부족',
      'Limited comparison',
      'Thiếu dữ liệu so sánh',
    ),
  };

  String sort(_TrendSort value) => switch (value) {
    _TrendSort.worsened => t('악화순', 'Slowdowns first', 'Chậm đi nhiều nhất'),
    _TrendSort.improved => t(
      '개선순',
      'Improvements first',
      'Cải thiện nhiều nhất',
    ),
    _TrendSort.samples => t('제공 건수순', 'Most samples', 'Nhiều mẫu nhất'),
  };
}
