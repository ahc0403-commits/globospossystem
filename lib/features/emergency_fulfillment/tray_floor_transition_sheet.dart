import 'package:flutter/material.dart';

import '../../core/ui/pos_design_tokens.dart';
import 'emergency_fulfillment_provider.dart';

typedef TrayFloorTransitionSubmit =
    Future<bool> Function(TrayFloorTransitionSummary summary);

class TrayFloorTransitionSheet extends StatefulWidget {
  const TrayFloorTransitionSheet({
    super.key,
    required this.firstFloor,
    required this.secondFloor,
    required this.unsupportedFloorQuantity,
    required this.onSubmit,
  });

  final TrayFloorTransitionSummary firstFloor;
  final TrayFloorTransitionSummary secondFloor;
  final int unsupportedFloorQuantity;
  final TrayFloorTransitionSubmit onSubmit;

  @override
  State<TrayFloorTransitionSheet> createState() =>
      _TrayFloorTransitionSheetState();
}

class _TrayFloorTransitionSheetState extends State<TrayFloorTransitionSheet> {
  final Map<String, Map<String, int>> _selectedByFloor = {};
  String? _busyFloor;
  String? _error;

  Map<String, int> _selectedFor(String floorLabel) =>
      _selectedByFloor.putIfAbsent(floorLabel, () => <String, int>{});

  int _selectedTotal(String floorLabel) => _selectedFor(
    floorLabel,
  ).values.fold(0, (total, quantity) => total + quantity);

  void _change(
    TrayFloorTransitionSummary summary,
    TrayFloorTransitionMenuGroup group,
    int delta,
  ) {
    if (_busyFloor != null) return;
    final selected = _selectedFor(summary.floorLabel);
    final current = selected[group.key] ?? 0;
    final next = (current + delta).clamp(0, group.quantity);
    setState(() {
      if (next == 0) {
        selected.remove(group.key);
      } else {
        selected[group.key] = next;
      }
      _error = null;
    });
  }

  Future<void> _submit(TrayFloorTransitionSummary summary) async {
    if (_busyFloor != null || _selectedTotal(summary.floorLabel) == 0) return;
    late final TrayFloorTransitionSummary selectedSummary;
    try {
      selectedSummary = allocateTrayFloorTransitionSelections(
        summary,
        _selectedFor(summary.floorLabel),
      );
    } catch (_) {
      setState(() => _error = _copy(context).stale);
      return;
    }
    setState(() {
      _busyFloor = summary.floorLabel;
      _error = null;
    });
    final success = await widget.onSubmit(selectedSummary);
    if (!mounted) return;
    if (success) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busyFloor = null;
      _error = _copy(context).stale;
    });
  }

  @override
  Widget build(BuildContext context) {
    final copy = _copy(context);
    final languageCode = Localizations.localeOf(context).languageCode;
    return Scaffold(
      key: const Key('tray_floor_transition_screen'),
      backgroundColor: PosSurfaceRole.background.fill,
      appBar: AppBar(
        leading: IconButton(
          key: const Key('tray_floor_transition_close'),
          onPressed: _busyFloor == null
              ? () => Navigator.of(context).pop()
              : null,
          icon: const Icon(Icons.close_rounded),
        ),
        title: Text(copy.title),
      ),
      body: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.unsupportedFloorQuantity > 0)
              Container(
                key: const Key('tray_floor_transition_unsupported_warning'),
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  color: PosColors.warning.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: PosColors.warning),
                ),
                child: Text(
                  copy.unsupported(widget.unsupportedFloorQuantity),
                  style: const TextStyle(fontWeight: FontWeight.w800),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  _error!,
                  key: const Key('tray_floor_transition_error'),
                  style: const TextStyle(
                    color: PosColors.danger,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            Expanded(
              child: Row(
                key: const Key('tray_floor_transition_columns'),
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: _FloorTransitionColumn(
                      summary: widget.firstFloor,
                      selected: _selectedFor(widget.firstFloor.floorLabel),
                      languageCode: languageCode,
                      copy: copy,
                      busy: _busyFloor != null,
                      onChange: (group, delta) =>
                          _change(widget.firstFloor, group, delta),
                      onSubmit: () => _submit(widget.firstFloor),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: _FloorTransitionColumn(
                      summary: widget.secondFloor,
                      selected: _selectedFor(widget.secondFloor.floorLabel),
                      languageCode: languageCode,
                      copy: copy,
                      busy: _busyFloor != null,
                      onChange: (group, delta) =>
                          _change(widget.secondFloor, group, delta),
                      onSubmit: () => _submit(widget.secondFloor),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FloorTransitionColumn extends StatelessWidget {
  const _FloorTransitionColumn({
    required this.summary,
    required this.selected,
    required this.languageCode,
    required this.copy,
    required this.busy,
    required this.onChange,
    required this.onSubmit,
  });

  final TrayFloorTransitionSummary summary;
  final Map<String, int> selected;
  final String languageCode;
  final _TrayFloorTransitionCopy copy;
  final bool busy;
  final void Function(TrayFloorTransitionMenuGroup group, int delta) onChange;
  final VoidCallback onSubmit;

  @override
  Widget build(BuildContext context) {
    final selectedTotal = selected.values.fold(
      0,
      (total, quantity) => total + quantity,
    );
    return Container(
      key: ValueKey('tray_floor_transition_column_${summary.floorLabel}'),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: PosColors.border, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            color: summary.floorLabel == '1F'
                ? const Color(0xFF1976D2)
                : const Color(0xFFD32F2F),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    summary.floorLabel,
                    style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
                Flexible(
                  child: Text(
                    copy.waiting(summary.totalQuantity),
                    key: ValueKey(
                      'tray_floor_transition_total_${summary.floorLabel}',
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.end,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: summary.groups.isEmpty
                ? Center(child: Text(copy.empty))
                : ListView.separated(
                    key: ValueKey(
                      'tray_floor_transition_list_${summary.floorLabel}',
                    ),
                    padding: const EdgeInsets.all(12),
                    itemCount: summary.groups.length,
                    separatorBuilder: (_, _) => const Divider(height: 18),
                    itemBuilder: (context, index) {
                      final group = summary.groups[index];
                      final selectedQuantity = selected[group.key] ?? 0;
                      final name = Text(
                        group.localizedName(languageCode),
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(fontWeight: FontWeight.w800),
                      );
                      final controls = Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            key: ValueKey(
                              'tray_floor_transition_minus_${summary.floorLabel}_${group.key}',
                            ),
                            tooltip: '-',
                            constraints: const BoxConstraints.tightFor(
                              width: 44,
                              height: 44,
                            ),
                            onPressed: !busy && selectedQuantity > 0
                                ? () => onChange(group, -1)
                                : null,
                            icon: const Icon(
                              Icons.remove_circle_outline_rounded,
                            ),
                          ),
                          SizedBox(
                            width: 54,
                            child: Text(
                              '$selectedQuantity/${group.quantity}',
                              key: ValueKey(
                                'tray_floor_transition_progress_${summary.floorLabel}_${group.key}',
                              ),
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                fontWeight: FontWeight.w900,
                              ),
                            ),
                          ),
                          IconButton(
                            key: ValueKey(
                              'tray_floor_transition_plus_${summary.floorLabel}_${group.key}',
                            ),
                            tooltip: '+',
                            constraints: const BoxConstraints.tightFor(
                              width: 44,
                              height: 44,
                            ),
                            onPressed:
                                !busy && selectedQuantity < group.quantity
                                ? () => onChange(group, 1)
                                : null,
                            icon: const Icon(Icons.add_circle_rounded),
                          ),
                        ],
                      );
                      return LayoutBuilder(
                        builder: (context, constraints) {
                          if (constraints.maxWidth < 260) {
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                name,
                                const SizedBox(height: 4),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: controls,
                                  ),
                                ),
                              ],
                            );
                          }
                          return Row(
                            children: [
                              Expanded(child: name),
                              const SizedBox(width: 8),
                              controls,
                            ],
                          );
                        },
                      );
                    },
                  ),
          ),
          Padding(
            padding: const EdgeInsets.all(12),
            child: LayoutBuilder(
              builder: (context, constraints) {
                final label = Text(
                  copy.complete(selectedTotal),
                  maxLines: 2,
                  textAlign: TextAlign.center,
                );
                final onPressed = !busy && selectedTotal > 0 ? onSubmit : null;
                final style = FilledButton.styleFrom(
                  minimumSize: const Size.fromHeight(56),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 10,
                  ),
                );
                if (constraints.maxWidth < 260) {
                  return FilledButton(
                    key: ValueKey(
                      'tray_floor_transition_confirm_${summary.floorLabel}',
                    ),
                    onPressed: onPressed,
                    style: style,
                    child: label,
                  );
                }
                return FilledButton.icon(
                  key: ValueKey(
                    'tray_floor_transition_confirm_${summary.floorLabel}',
                  ),
                  onPressed: onPressed,
                  icon: const Icon(Icons.send_rounded),
                  label: label,
                  style: style,
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _TrayFloorTransitionCopy {
  const _TrayFloorTransitionCopy(this.languageCode);

  final String languageCode;

  String _pick(String ko, String vi, String en) => switch (languageCode) {
    'vi' => vi,
    'en' => en,
    _ => ko,
  };

  String get title => _pick('층별 전달', 'Chuyển theo tầng', 'Floor handoff');
  String waiting(int quantity) =>
      _pick('대기 $quantity개', 'Chờ $quantity món', '$quantity waiting');
  String get empty =>
      _pick('전달할 음식이 없습니다.', 'Không có món cần chuyển.', 'No food to send.');
  String complete(int quantity) =>
      _pick('완료 · $quantity', 'Hoàn tất · $quantity', 'Complete · $quantity');
  String unsupported(int quantity) => _pick(
    '층 확인이 필요한 음식 $quantity개는 자동 전송하지 않습니다.',
    '$quantity món cần kiểm tra tầng và sẽ không được tự động gửi.',
    '$quantity item(s) need a floor check and will not be sent automatically.',
  );
  String get stale => _pick(
    '대기 수량이 변경되었습니다. 닫은 뒤 다시 열어 주세요.',
    'Số lượng chờ đã thay đổi. Hãy đóng và mở lại.',
    'Waiting quantities changed. Close and reopen this screen.',
  );
}

_TrayFloorTransitionCopy _copy(BuildContext context) =>
    _TrayFloorTransitionCopy(Localizations.localeOf(context).languageCode);
