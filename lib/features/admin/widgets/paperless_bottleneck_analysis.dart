import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/i18n/menu_localization.dart';
import '../../../core/ui/pos_design_tokens.dart';
import '../../../main.dart';
import '../../report/report_provider.dart';

typedef PaperlessBottleneckLoader =
    Future<Map<String, dynamic>> Function({
      required String storeId,
      required DateTime startDate,
      required DateTime endDate,
      required String stage,
      int? hour,
      String? menuKey,
    });

List<Map<String, dynamic>> _rows(dynamic value) => (value as List? ?? const [])
    .whereType<Map>()
    .map((row) => Map<String, dynamic>.from(row))
    .toList();
int _count(dynamic value) => (value as num?)?.toInt() ?? 0;
int? _seconds(dynamic value) => (value as num?)?.toInt();

class PaperlessBottleneckMetric {
  PaperlessBottleneckMetric(this.raw);
  final Map<String, dynamic> raw;
  String get stage => raw['stage']?.toString() ?? '';
  int get currentCount => _count(raw['current_count']);
  int get baselineCount => _count(raw['baseline_count']);
  int? value(bool p90, {bool baseline = false}) => _seconds(
    raw['${baseline ? 'baseline' : 'current'}_${p90 ? 'p90' : 'mean'}'],
  );
  int? delta(bool p90) {
    final current = value(p90), baseline = value(p90, baseline: true);
    final minimum = p90 ? 20 : 5;
    return currentCount < minimum ||
            baselineCount < minimum ||
            current == null ||
            baseline == null
        ? null
        : current - baseline;
  }
}

class PaperlessBottleneckAnalysis {
  PaperlessBottleneckAnalysis(this.raw);
  final Map<String, dynamic> raw;
  List<PaperlessBottleneckMetric> get stages =>
      _rows(raw['stages']).map(PaperlessBottleneckMetric.new).toList();
  List<Map<String, dynamic>> get hours => _rows(raw['hours']);
  List<Map<String, dynamic>> get menus => _rows(raw['menus']);
  List<Map<String, dynamic>> get points => _rows(raw['points']);
  List<Map<String, dynamic>> get samples => _rows(raw['samples']);
  PaperlessBottleneckMetric metric(String stage, {int? hour}) {
    final values = hour == null ? _rows(raw['stages']) : hours;
    return PaperlessBottleneckMetric(
      values.firstWhere(
        (row) => row['stage'] == stage && (hour == null || row['hour'] == hour),
        orElse: () => {'stage': stage},
      ),
    );
  }
}

class PaperlessBottleneckSection extends StatefulWidget {
  const PaperlessBottleneckSection({
    super.key,
    required this.storeId,
    required this.startDate,
    required this.endDate,
    this.loader,
    this.loadLive = true,
  });
  final String storeId;
  final DateTime startDate, endDate;
  final PaperlessBottleneckLoader? loader;
  final bool loadLive;
  @override
  State<PaperlessBottleneckSection> createState() => _BottleneckState();
}

class _BottleneckState extends State<PaperlessBottleneckSection> {
  PaperlessBottleneckAnalysis? _data;
  String _stage = 'kitchen';
  int? _hour;
  String? _menuKey;
  String? _menuName;
  bool _p90 = false, _loading = true, _failed = false;
  bool _mobileTrend = false;
  int _generation = 0, _hourStart = 12;
  static const _stages = ['kitchen', 'handoff', 'floor'];
  static const _orange = Color(0xFFC65100);
  static const _blue = Color(0xFF2563EB);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant PaperlessBottleneckSection oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.storeId != widget.storeId ||
        oldWidget.startDate != widget.startDate ||
        oldWidget.endDate != widget.endDate ||
        oldWidget.loader != widget.loader) {
      _data = null;
      _hour = null;
      _menuKey = null;
      _menuName = null;
      _load();
    }
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (!widget.loadLive && widget.loader == null) {
      setState(() => _loading = false);
      return;
    }
    setState(() {
      _loading = true;
      _failed = false;
    });
    try {
      final Map<String, dynamic> result;
      if (widget.loader case final loader?) {
        result = await loader(
          storeId: widget.storeId,
          startDate: widget.startDate,
          endDate: widget.endDate,
          stage: _stage,
          hour: _hour,
          menuKey: _menuKey,
        );
      } else {
        final range = reportUtcRange(widget.startDate, widget.endDate);
        final response = await supabase.rpc(
          'get_paperless_bottleneck_analysis',
          params: {
            'p_store_id': widget.storeId,
            'p_from': range.startUtc.toIso8601String(),
            'p_to': range.endExclusiveUtc.toIso8601String(),
            'p_stage': _stage,
            'p_hour': _hour,
            'p_menu_key': _menuKey,
          },
        );
        result = Map<String, dynamic>.from(response as Map);
      }
      if (!mounted || generation != _generation) return;
      setState(() {
        _data = PaperlessBottleneckAnalysis(result);
        _loading = false;
      });
      // A floor-direct-only store has no kitchen cohort. Select its actual
      // recorded stage rather than inventing zero kitchen/transfer times.
      if (_hour == null &&
          _menuKey == null &&
          _data!.metric(_stage).currentCount == 0 &&
          _data!.metric('floor').currentCount > 0 &&
          _stage != 'floor') {
        _stage = 'floor';
        await _load();
      }
    } catch (_) {
      if (!mounted || generation != _generation) return;
      setState(() {
        _failed = true;
        _loading = false;
      });
    }
  }

  void _select(String stage, int? hour, [Map<String, dynamic>? menu]) {
    _stage = stage;
    _hour = hour;
    _menuKey = menu?['menu_key']?.toString();
    _menuName = menu == null
        ? null
        : localizedMenuName(menu, Localizations.localeOf(context).languageCode);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final copy = _Copy(Localizations.localeOf(context).languageCode);
    final data = _data;
    if (!widget.loadLive && widget.loader == null) {
      return const SizedBox.shrink();
    }
    return Container(
      key: const Key('paperless_bottleneck_analysis'),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            copy.t(
              '어느 단계가 · 언제 · 어떤 메뉴에서 느려졌나요?',
              'Which stage, hour and menu became slower?',
              'Chặng nào, giờ nào, món nào chậm hơn?',
            ),
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              ChoiceChip(
                label: Text(copy.t('평균', 'Mean', 'Trung bình')),
                selected: !_p90,
                onSelected: (_) => setState(() => _p90 = false),
              ),
              ChoiceChip(
                label: const Text('P90'),
                selected: _p90,
                onSelected: (_) => setState(() => _p90 = true),
              ),
              Text(
                _p90
                    ? copy.t(
                        '90%가 이 시간 안에 완료 · 20건 이상',
                        '90% complete within this time · minimum 20 samples',
                        '90% hoàn tất trong thời gian này · tối thiểu 20 mẫu',
                      )
                    : copy.t(
                        '완료 메뉴 표본 · 증감 비교는 각 기간 5건 이상',
                        'Completed menu samples · changes require 5 in each period',
                        'Mẫu món hoàn tất · so sánh cần 5 mẫu mỗi kỳ',
                      ),
              ),
              IconButton(
                tooltip: copy.t('새로고침', 'Refresh', 'Làm mới'),
                onPressed: _loading ? null : _load,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          if (_loading) const LinearProgressIndicator(),
          if (_failed)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      copy.t(
                        '병목 분석을 불러오지 못했습니다.',
                        'Could not load bottleneck analysis.',
                        'Không tải được phân tích điểm nghẽn.',
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _load,
                    child: Text(copy.t('재시도', 'Retry', 'Thử lại')),
                  ),
                ],
              ),
            ),
          if (!_failed && data != null) ...[
            Text(
              '${copy.t('고정 비교 기간', 'Fixed comparison', 'Kỳ so sánh cố định')}: '
              '${data.raw['baseline_from']} – ${data.raw['baseline_to']}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            _insight(data, copy),
            const SizedBox(height: 12),
            LayoutBuilder(
              builder: (context, box) {
                final stageChart = _stageChart(data, copy);
                final trend = _trend(data, copy);
                if (box.maxWidth < 900 ||
                    MediaQuery.textScalerOf(context).scale(1) > 1.4) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      stageChart,
                      const SizedBox(height: 18),
                      Wrap(
                        spacing: 8,
                        children: [
                          ChoiceChip(
                            label: Text(copy.t('시간대', 'Hours', 'Khung giờ')),
                            selected: !_mobileTrend,
                            onSelected: (_) =>
                                setState(() => _mobileTrend = false),
                          ),
                          ChoiceChip(
                            label: Text(copy.t('기간 추이', 'Trend', 'Xu hướng')),
                            selected: _mobileTrend,
                            onSelected: (_) =>
                                setState(() => _mobileTrend = true),
                          ),
                        ],
                      ),
                      if (_mobileTrend) ...[const SizedBox(height: 12), trend],
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(flex: 6, child: stageChart),
                    const SizedBox(width: 24),
                    Expanded(flex: 5, child: trend),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, box) =>
                  _mobileTrend &&
                      (box.maxWidth < 900 ||
                          MediaQuery.textScalerOf(context).scale(1) > 1.4)
                  ? const SizedBox.shrink()
                  : _hours(data, copy),
            ),
            const SizedBox(height: 18),
            if (_loading)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  copy.t(
                    '선택한 구간을 불러오는 중…',
                    'Loading selected slice…',
                    'Đang tải khoảng đã chọn…',
                  ),
                ),
              )
            else ...[
              _menus(data, copy),
              if (_menuKey != null) ...[
                const SizedBox(height: 16),
                _samples(data, copy),
              ],
            ],
            const SizedBox(height: 12),
            Text(
              copy.t(
                '병목 후보를 보여주며 원인을 단정하지 않습니다. 목표시간 초과 판정과 현재 대기량은 포함하지 않습니다.',
                'Shows bottleneck candidates, not causal proof. No SLA or live backlog claim.',
                'Hiển thị điểm nghẽn tiềm năng, không kết luận nguyên nhân. Không đánh giá SLA hay hàng chờ hiện tại.',
              ),
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _heading(String title) => Padding(
    padding: const EdgeInsets.only(bottom: 10),
    child: Text(
      title,
      style: Theme.of(
        context,
      ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w800),
    ),
  );

  Widget _insight(PaperlessBottleneckAnalysis data, _Copy copy) {
    final comparable = data.stages.where((m) => m.delta(_p90) != null).toList()
      ..sort((a, b) => b.delta(_p90)!.compareTo(a.delta(_p90)!));
    final worst = comparable.firstOrNull;
    final message = worst == null
        ? copy.t(
            '비교 가능한 표본이 아직 부족합니다.',
            'Not enough comparable samples yet.',
            'Chưa đủ mẫu để so sánh.',
          )
        : worst.delta(_p90)! <= 0
        ? copy.t(
            '비교 가능한 단계에서 소요시간 증가가 없습니다.',
            'No increase in comparable stages.',
            'Không tăng thời gian ở các chặng so sánh được.',
          )
        : '${copy.t('전기 대비 가장 증가한 구간', 'Largest increase', 'Chặng tăng nhiều nhất')}: '
              '${copy.stage(worst.stage)} ${copy.delta(worst.delta(_p90))}';
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFFFF2E7),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Text(message, style: const TextStyle(fontWeight: FontWeight.w700)),
    );
  }

  Widget _stageChart(PaperlessBottleneckAnalysis data, _Copy copy) {
    final maximum = data.stages.fold<int>(
      60,
      (value, m) => math.max(
        value,
        math.max(m.value(_p90) ?? 0, m.value(_p90, baseline: true) ?? 0),
      ),
    );
    final scale = math.max(300, (maximum / 300).ceil() * 300);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          copy.t(
            '어느 단계가 느려졌나요?',
            'Which stage became slower?',
            'Chặng nào chậm hơn?',
          ),
        ),
        Wrap(
          spacing: 16,
          children: [
            Text(
              '■ ${copy.t('이전 기간', 'Previous period', 'Kỳ trước')}',
              style: const TextStyle(color: Color(0xFF6B7280)),
            ),
            Text(
              '■ ${copy.t('선택 기간', 'Selected period', 'Kỳ chọn')}',
              style: const TextStyle(color: _blue),
            ),
          ],
        ),
        for (final stage in _stages)
          Builder(
            builder: (context) {
              final metric = data.metric(stage);
              final change = metric.delta(_p90);
              final color = change != null && change > 0 ? _orange : _blue;
              return Semantics(
                button: true,
                selected: stage == _stage,
                label:
                    '${copy.stage(stage)}, ${copy.duration(metric.value(_p90))}, ${copy.delta(change)}',
                child: InkWell(
                  key: Key('bottleneck_stage_$stage'),
                  onTap: _loading ? null : () => _select(stage, null),
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: 12,
                      horizontal: 6,
                    ),
                    color: stage == _stage ? const Color(0xFFF0F5FF) : null,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          spacing: 10,
                          runSpacing: 4,
                          children: [
                            Text(
                              copy.stage(stage),
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              copy.delta(change),
                              style: TextStyle(
                                color: color,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${copy.t('이전', 'Previous', 'Trước')} n=${metric.baselineCount} · '
                              '${copy.t('현재', 'Current', 'Nay')} n=${metric.currentCount}',
                              style: Theme.of(context).textTheme.bodySmall,
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        _bar(
                          metric.value(_p90, baseline: true),
                          scale,
                          const Color(0xFF9CA3AF),
                          copy,
                        ),
                        const SizedBox(height: 5),
                        _bar(metric.value(_p90), scale, color, copy),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        Padding(
          padding: const EdgeInsets.only(left: 6, right: 84),
          child: Row(
            children: [
              for (var tick = 0; tick <= 2; tick++)
                Expanded(
                  child: Text(
                    '${(scale * tick / 120).toStringAsFixed(1)} ${copy.t('분', 'min', 'phút')}',
                    textAlign: tick == 0
                        ? TextAlign.left
                        : tick == 2
                        ? TextAlign.right
                        : TextAlign.center,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
          ),
        ),
        Text(
          copy.t(
            '표본이 없는 단계는 미기록 또는 해당 동선 없음입니다.',
            'No samples: unrecorded or not part of this workflow.',
            'Không có mẫu: chưa ghi nhận hoặc không thuộc quy trình này.',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _bar(int? seconds, int scale, Color color, _Copy copy) => Row(
    children: [
      Expanded(
        child: LayoutBuilder(
          builder: (context, box) => Align(
            alignment: Alignment.centerLeft,
            child: Container(
              height: 12,
              width: seconds == null
                  ? 0
                  : box.maxWidth * (seconds / scale).clamp(0, 1),
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
        ),
      ),
      const SizedBox(width: 6),
      SizedBox(
        width: 72,
        child: Text(
          copy.duration(seconds),
          style: TextStyle(
            color: seconds == null ? PosColors.textMuted : color,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    ],
  );

  Widget _trend(PaperlessBottleneckAnalysis data, _Copy copy) {
    final unit = data.raw['bucket_unit']?.toString() ?? 'day';
    DateTime bucket(DateTime date) => unit == 'month'
        ? DateTime(date.year, date.month)
        : unit == 'week'
        ? DateTime(
            date.year,
            date.month,
            date.day,
          ).subtract(Duration(days: date.weekday - 1))
        : DateTime(date.year, date.month, date.day);
    final dates = <DateTime>[];
    for (var date = bucket(widget.startDate); !date.isAfter(widget.endDate);) {
      dates.add(date);
      date = unit == 'month'
          ? DateTime(date.year, date.month + 1)
          : date.add(Duration(days: unit == 'week' ? 7 : 1));
    }
    final values = {for (final point in data.points) point['date']: point};
    final baseline = (data.raw['baseline'] as Map?) ?? const {};
    final baselineSeconds = _seconds(baseline[_p90 ? 'p90' : 'mean']);
    final spots = [
      for (var i = 0; i < dates.length; i++)
        if (_seconds(
              values[DateFormat('yyyy-MM-dd').format(dates[i])]?[_p90
                  ? 'p90'
                  : 'mean'],
            )
            case final value?)
          FlSpot(i.toDouble(), value / 60)
        else
          FlSpot.nullSpot,
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          '${copy.t('선택 구간 추이', 'Selected stage trend', 'Xu hướng chặng chọn')}: ${copy.stage(_stage)}',
        ),
        Text(
          '${_hour == null ? copy.t('전체 시간대', 'All hours', 'Mọi giờ') : '${_hour}h'}'
          '${_menuName == null ? '' : ' · $_menuName'}',
        ),
        const SizedBox(height: 12),
        if (spots.every((spot) => spot == FlSpot.nullSpot))
          SizedBox(
            height: 180,
            child: Center(
              child: Text(
                copy.t(
                  '추이를 표시할 완료 표본이 부족합니다.',
                  'Not enough completed samples for this trend.',
                  'Chưa đủ mẫu hoàn tất để hiển thị xu hướng.',
                ),
              ),
            ),
          )
        else
          SizedBox(
            height: 220,
            child: Padding(
              padding: const EdgeInsets.only(right: 14, top: 12),
              child: LineChart(
                LineChartData(
                  minX: 0,
                  maxX: math.max(1, dates.length - 1).toDouble(),
                  minY: 0,
                  gridData: const FlGridData(
                    show: true,
                    drawVerticalLine: false,
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
                      axisNameWidget: Text(copy.t('분', 'min', 'phút')),
                      sideTitles: const SideTitles(
                        showTitles: true,
                        reservedSize: 38,
                      ),
                    ),
                    bottomTitles: AxisTitles(
                      sideTitles: SideTitles(
                        showTitles: true,
                        reservedSize: 30,
                        interval: math
                            .max(1, (dates.length / 4).ceil())
                            .toDouble(),
                        getTitlesWidget: (value, meta) {
                          final i = value.toInt();
                          return i < 0 || i >= dates.length || value != i
                              ? const SizedBox.shrink()
                              : Text(
                                  DateFormat('MM/dd').format(dates[i]),
                                  style: const TextStyle(fontSize: 10),
                                );
                        },
                      ),
                    ),
                  ),
                  lineBarsData: [
                    LineChartBarData(
                      spots: spots,
                      color: _blue,
                      barWidth: 3,
                      dotData: const FlDotData(show: true),
                    ),
                    if (baselineSeconds != null)
                      LineChartBarData(
                        spots: [
                          FlSpot(0, baselineSeconds / 60),
                          FlSpot(
                            math.max(1, dates.length - 1).toDouble(),
                            baselineSeconds / 60,
                          ),
                        ],
                        color: const Color(0xFF6B7280),
                        dashArray: [6, 4],
                        dotData: const FlDotData(show: false),
                      ),
                  ],
                  lineTouchData: LineTouchData(
                    touchTooltipData: LineTouchTooltipData(
                      getTooltipItems: (spots) => spots.map((spot) {
                        final i = spot.x.toInt().clamp(0, dates.length - 1);
                        final count = _count(
                          values[DateFormat(
                            'yyyy-MM-dd',
                          ).format(dates[i])]?['count'],
                        );
                        return LineTooltipItem(
                          '${DateFormat('MM/dd').format(dates[i])}\n'
                          '${copy.duration((spot.y * 60).round())}${spot.barIndex == 0 ? '\nn=$count' : ''}',
                          const TextStyle(color: Colors.white),
                        );
                      }).toList(),
                    ),
                  ),
                ),
              ),
            ),
          ),
        Text(
          '${copy.t('점선: 고정 이전 기간', 'Dashed: fixed previous period', 'Nét đứt: kỳ trước cố định')} '
          '${copy.duration(baselineSeconds)} · n=${_count(baseline['count'])}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _hours(PaperlessBottleneckAnalysis data, _Copy copy) => LayoutBuilder(
    builder: (context, box) {
      final columns =
          box.maxWidth < 650 || MediaQuery.textScalerOf(context).scale(1) > 1.4
          ? 4
          : 12;
      final start = _hourStart.clamp(0, 24 - columns);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _heading(
            copy.t(
              '언제 집중되나요? 단계 × 접수 시간대',
              'When does it concentrate? Stage × receipt hour',
              'Tập trung lúc nào? Chặng × giờ nhận',
            ),
          ),
          Wrap(
            spacing: 10,
            runSpacing: 4,
            children: [
              Text(
                copy.t(
                  '전기 대비: 파랑 개선 · 주황 악화 · 숫자=증감(분)',
                  'Vs previous: blue faster · orange slower · numbers = change (min)',
                  'So kỳ trước: xanh nhanh hơn · cam chậm hơn · số = chênh lệch (phút)',
                ),
              ),
              TextButton(
                onPressed: _loading ? null : () => _select(_stage, null),
                child: Text(copy.t('시간대 선택 해제', 'All hours', 'Bỏ chọn giờ')),
              ),
            ],
          ),
          Row(
            children: [
              IconButton(
                key: const Key('bottleneck_hours_previous'),
                tooltip: copy.t('이전 시간대', 'Earlier hours', 'Giờ trước'),
                onPressed: start == 0
                    ? null
                    : () => setState(
                        () => _hourStart = math.max(0, start - columns),
                      ),
                icon: const Icon(Icons.chevron_left),
              ),
              Expanded(
                child: Text(
                  '${start}h – ${start + columns - 1}h / 00–23h',
                  textAlign: TextAlign.center,
                ),
              ),
              IconButton(
                key: const Key('bottleneck_hours_next'),
                tooltip: copy.t('다음 시간대', 'Later hours', 'Giờ sau'),
                onPressed: start + columns == 24
                    ? null
                    : () => setState(
                        () => _hourStart = math.min(
                          24 - columns,
                          start + columns,
                        ),
                      ),
                icon: const Icon(Icons.chevron_right),
              ),
            ],
          ),
          Row(
            children: [
              const SizedBox(width: 62),
              for (var hour = start; hour < start + columns; hour++)
                Expanded(child: Text('${hour}h', textAlign: TextAlign.center)),
            ],
          ),
          for (final stage in _stages)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 3),
              child: Row(
                children: [
                  SizedBox(width: 62, child: Text(copy.stage(stage))),
                  for (var hour = start; hour < start + columns; hour++)
                    Expanded(
                      child: Builder(
                        builder: (context) {
                          final metric = data.metric(stage, hour: hour);
                          final delta = metric.delta(_p90);
                          final color = delta == null
                              ? const Color(0xFFF0F1F3)
                              : delta == 0
                              ? const Color(0xFFF8FAFC)
                              : Color.lerp(
                                  Colors.white,
                                  delta > 0
                                      ? const Color(0xFFFFB478)
                                      : const Color(0xFF8CB5FF),
                                  (delta.abs() / 300).clamp(0.1, 1),
                                )!;
                          return Padding(
                            padding: const EdgeInsets.all(2),
                            child: Tooltip(
                              message:
                                  '${copy.stage(stage)} ${hour}h · ${copy.duration(metric.value(_p90))}\n'
                                  '${copy.delta(delta)} · n=${metric.currentCount}/${metric.baselineCount}',
                              child: Semantics(
                                button: true,
                                label:
                                    '${copy.stage(stage)}, ${hour}h, ${copy.delta(delta)}, '
                                    'n=${metric.currentCount}/${metric.baselineCount}',
                                child: InkWell(
                                  key: Key('bottleneck_cell_${stage}_$hour'),
                                  onTap: _loading
                                      ? null
                                      : () => _select(stage, hour),
                                  child: Container(
                                    constraints: const BoxConstraints(
                                      minHeight: 54,
                                    ),
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 6,
                                    ),
                                    decoration: BoxDecoration(
                                      color: color,
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                        color: _stage == stage && _hour == hour
                                            ? _blue
                                            : Colors.transparent,
                                        width: 2,
                                      ),
                                    ),
                                    child: Column(
                                      mainAxisAlignment:
                                          MainAxisAlignment.center,
                                      children: [
                                        Text(
                                          delta == null
                                              ? '—'
                                              : '${delta > 0 ? '+' : ''}${(delta / 60).toStringAsFixed(1)}',
                                          style: const TextStyle(
                                            fontWeight: FontWeight.w700,
                                            fontSize: 12,
                                          ),
                                        ),
                                        Text(
                                          'n=${metric.currentCount}',
                                          style: const TextStyle(fontSize: 10),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                ],
              ),
            ),
          Text(
            copy.t(
              '회색: 미기록 또는 비교 표본 부족 · 접수 시각은 베트남 시간',
              'Grey: missing or insufficient comparison · receipt times in Vietnam',
              'Xám: thiếu ghi nhận hoặc mẫu so sánh · giờ nhận tại Việt Nam',
            ),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      );
    },
  );

  Widget _menus(PaperlessBottleneckAnalysis data, _Copy copy) {
    final menus = data.menus;
    final maximum = menus.fold<int>(
      1,
      (v, menu) => math.max(v, _count(menu['extra_seconds'])),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _heading(
          '${copy.stage(_stage)} · ${_hour == null ? copy.t('전체 시간대', 'All hours', 'Mọi giờ') : '${_hour}h'} / '
          '${copy.t('우선 확인할 메뉴', 'Menus to review first', 'Món cần kiểm tra trước')}',
        ),
        Text(
          copy.t(
            '전기 대비 추가 소요 = 메뉴별 평균 증가분 × 현재 완료 표본 수. 인력 절감 시간이나 원인 확정값이 아닙니다.',
            'Extra time = menu mean increase × current completed samples; not labor savings or causal attribution.',
            'Thời gian tăng = mức tăng trung bình món × số mẫu hoàn tất; không phải tiết kiệm nhân công hay kết luận nguyên nhân.',
          ),
          style: Theme.of(context).textTheme.bodySmall,
        ),
        if (menus.isEmpty)
          Padding(
            padding: const EdgeInsets.all(20),
            child: Text(
              copy.t(
                '선택한 구간의 완료 메뉴가 없습니다.',
                'No completed menus in this slice.',
                'Không có món hoàn tất trong khoảng chọn.',
              ),
            ),
          ),
        for (var i = 0; i < menus.length; i++)
          Builder(
            builder: (context) {
              final menu = menus[i];
              final metric = PaperlessBottleneckMetric(menu);
              final extra = _seconds(menu['extra_seconds']);
              final name = localizedMenuName(
                menu,
                Localizations.localeOf(context).languageCode,
              );
              return Card(
                elevation: 0,
                color: _menuKey == menu['menu_key']
                    ? const Color(0xFFF0F5FF)
                    : const Color(0xFFF8FAFC),
                child: InkWell(
                  key: Key('bottleneck_menu_${menu['menu_key']}'),
                  onTap: () => _select(_stage, _hour, menu),
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Wrap(
                          spacing: 12,
                          runSpacing: 4,
                          children: [
                            Text(
                              '${i + 1}. $name',
                              style: const TextStyle(
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            Text(
                              '${copy.t('추가 소요', 'Extra time', 'Thời gian tăng')} ${copy.duration(extra)}',
                              style: const TextStyle(
                                color: _orange,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            Text(
                              '${copy.delta(metric.delta(false))} · n=${metric.currentCount}/${metric.baselineCount}',
                            ),
                            Text(
                              copy.t(
                                '주문 타임라인 ›',
                                'Order timelines ›',
                                'Dòng thời gian đơn ›',
                              ),
                              style: const TextStyle(color: _blue),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        LayoutBuilder(
                          builder: (context, box) => Align(
                            alignment: Alignment.centerLeft,
                            child: Container(
                              height: 7,
                              width: extra == null
                                  ? 0
                                  : box.maxWidth * extra / maximum,
                              decoration: BoxDecoration(
                                color: _orange,
                                borderRadius: BorderRadius.circular(3),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            },
          ),
        Text(
          '${copy.t('표시', 'Showing', 'Hiển thị')} ${menus.length}/${_count(data.raw['menu_count'])} · '
          '${copy.t('추가 소요 상위 20개', 'Top 20 by extra time', '20 món tăng thời gian nhiều nhất')}',
          style: Theme.of(context).textTheme.bodySmall,
        ),
      ],
    );
  }

  Widget _samples(PaperlessBottleneckAnalysis data, _Copy copy) => Column(
    key: const Key('bottleneck_order_timelines'),
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      _heading(
        '${copy.t('실제 주문 타임라인', 'Recorded order timelines', 'Dòng thời gian đơn đã ghi')}: $_menuName',
      ),
      Text(
        '${data.samples.length}/${_count(data.raw['sample_count'])} · '
        '${copy.t('선택 단계가 오래 걸린 완료 표본 최대 30개', 'Up to 30 slowest completed samples in the selected stage', 'Tối đa 30 mẫu hoàn tất chậm nhất ở chặng chọn')}',
      ),
      TextButton(
        onPressed: () => _select(_stage, _hour),
        child: Text(copy.t('메뉴 선택 해제', 'Clear menu selection', 'Bỏ chọn món')),
      ),
      for (final sample in data.samples)
        ExpansionTile(
          key: Key('bottleneck_sample_${sample['sample_key']}'),
          title: Text(
            '${copy.t('주문', 'Order', 'Đơn')} ${sample['order_id'].toString().split('-').last}',
          ),
          subtitle: Text(
            '${copy.stage(_stage)} ${copy.duration(_seconds(sample['seconds']))} · '
            '${sample['workflow'] == 'kitchen_direct_to_floor'
                ? copy.t('주방→층 직접 전달', 'Kitchen directly to floor', 'Bếp giao thẳng tầng')
                : sample['workflow'] == 'floor_direct'
                ? copy.t('층 직접 처리', 'Floor direct', 'Tầng xử lý trực tiếp')
                : copy.t('주방→인계→서빙', 'Kitchen→handoff→service', 'Bếp→bàn giao→phục vụ')}',
          ),
          children: [
            PaperlessRecordedTimeline(
              sample: sample,
              languageCode: Localizations.localeOf(context).languageCode,
            ),
          ],
        ),
    ],
  );
}

class PaperlessRecordedTimeline extends StatelessWidget {
  const PaperlessRecordedTimeline({
    super.key,
    required this.sample,
    required this.languageCode,
  });
  final Map<String, dynamic> sample;
  final String languageCode;
  @override
  Widget build(BuildContext context) {
    final copy = _Copy(languageCode);
    final keys = ['received_at', 'kitchen_done_at', 'handoff_at', 'served_at'];
    final names = [
      copy.t('접수', 'Received', 'Nhận'),
      copy.t('주방 완료', 'Kitchen done', 'Bếp xong'),
      copy.t('인계', 'Handoff', 'Bàn giao'),
      copy.t('서빙 완료', 'Served', 'Phục vụ xong'),
    ];
    final dates = keys
        .map((key) => DateTime.tryParse(sample[key]?.toString() ?? '')?.toUtc())
        .toList();
    final first = dates.first, last = dates.last;
    final duration = first == null || last == null
        ? 0
        : last.difference(first).inMilliseconds;
    final ordered =
        duration > 0 &&
        dates.whereType<DateTime>().every(
          (d) => !d.isBefore(first!) && !d.isAfter(last!),
        ) &&
        [
          for (var i = 1; i < dates.length; i++)
            if (dates[i] != null && dates[i - 1] != null)
              !dates[i]!.isBefore(dates[i - 1]!),
        ].every((value) => value);
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (ordered)
            LayoutBuilder(
              builder: (context, box) => SizedBox(
                height: 24,
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 8,
                      child: Container(
                        height: 8,
                        color: const Color(0xFFE5E7EB),
                      ),
                    ),
                    for (var i = 1; i < dates.length; i++)
                      if (dates[i] != null && dates[i - 1] != null)
                        Positioned(
                          left:
                              (box.maxWidth - 8) *
                              dates[i - 1]!.difference(first!).inMilliseconds /
                              duration,
                          width:
                              (box.maxWidth - 8) *
                              dates[i]!
                                  .difference(dates[i - 1]!)
                                  .inMilliseconds /
                              duration,
                          top: 8,
                          child: Container(
                            height: 8,
                            color: [
                              Colors.transparent,
                              const Color(0xFFC65100),
                              const Color(0xFF2563EB),
                              const Color(0xFF0F766E),
                            ][i],
                          ),
                        ),
                    for (var i = 0; i < dates.length; i++)
                      if (dates[i] != null)
                        Positioned(
                          left:
                              (box.maxWidth - 8) *
                              dates[i]!.difference(first!).inMilliseconds /
                              duration,
                          top: 5,
                          child: Container(
                            width: 8,
                            height: 14,
                            color: const Color(0xFF334155),
                          ),
                        ),
                  ],
                ),
              ),
            ),
          for (var i = 0; i < dates.length; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Wrap(
                spacing: 12,
                runSpacing: 4,
                children: [
                  Text(
                    names[i],
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                  Text(
                    dates[i] == null
                        ? copy.t(
                            '미기록 / 해당 동선 없음',
                            'Unrecorded / not applicable',
                            'Chưa ghi nhận / không áp dụng',
                          )
                        : copy.timestamp(dates[i]!),
                  ),
                  if (i > 0 &&
                      dates[i] != null &&
                      dates[i - 1] != null &&
                      !dates[i]!.isBefore(dates[i - 1]!))
                    Text(
                      copy.duration(
                        dates[i]!.difference(dates[i - 1]!).inSeconds,
                      ),
                    ),
                ],
              ),
            ),
          if (!ordered && first != null && last != null)
            Text(
              copy.t(
                '이벤트 시각 순서를 확인해야 합니다.',
                'Review event timestamp order.',
                'Cần kiểm tra thứ tự thời gian sự kiện.',
              ),
            ),
        ],
      ),
    );
  }
}

class _Copy {
  const _Copy(this.language);
  final String language;
  String t(String ko, String en, String vi) => language == 'ko'
      ? ko
      : language == 'vi'
      ? vi
      : en;
  String stage(String stage) => switch (stage) {
    'kitchen' => t('주방', 'Kitchen', 'Bếp'),
    'handoff' => t('인계', 'Handoff', 'Bàn giao'),
    _ => t('서빙', 'Service', 'Phục vụ'),
  };
  String timestamp(DateTime value) {
    final time = DateFormat(
      'MM/dd HH:mm:ss',
    ).format(value.toUtc().add(const Duration(hours: 7)));
    return t(
      '$time (베트남, UTC+7)',
      '$time (Vietnam, UTC+7)',
      '$time (Việt Nam, UTC+7)',
    );
  }

  String duration(int? seconds) => seconds == null
      ? '—'
      : '${(seconds / 60).toStringAsFixed(1)} ${t('분', 'min', 'phút')}';
  String delta(int? seconds) => seconds == null
      ? t('비교 보류', 'Insufficient samples', 'Chưa đủ mẫu')
      : '${seconds > 0 ? '+' : ''}${duration(seconds)}';
}
