import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/ui/pos_design_tokens.dart';
import 'emergency_fulfillment_provider.dart';

typedef KitchenChecketSubmit =
    Future<bool> Function(Map<String, int> selections);

class KitchenChecketHandoffSheet extends StatefulWidget {
  const KitchenChecketHandoffSheet({
    super.key,
    required this.groups,
    required this.onSubmit,
  });

  final List<KitchenChecketMenuGroup> groups;
  final KitchenChecketSubmit onSubmit;

  @override
  State<KitchenChecketHandoffSheet> createState() =>
      _KitchenChecketHandoffSheetState();
}

class _KitchenChecketHandoffSheetState
    extends State<KitchenChecketHandoffSheet> {
  static const _groupsPerColumn = 10;
  static const _columnCount = 3;
  static const _groupsPerPage = _groupsPerColumn * _columnCount;

  final Map<String, int> _selected = {};
  int _page = 0;
  bool _busy = false;
  String? _error;

  int get _pageCount =>
      math.max(1, (widget.groups.length / _groupsPerPage).ceil());

  int get _selectedTotal =>
      _selected.values.fold(0, (total, quantity) => total + quantity);

  void _change(KitchenChecketMenuGroup group, int delta) {
    if (_busy) return;
    final current = _selected[group.key] ?? 0;
    final next = math.max(0, math.min(group.pendingQuantity, current + delta));
    setState(() {
      _selected[group.key] = next;
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_busy || _selectedTotal == 0) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final success = await widget.onSubmit({
      for (final entry in _selected.entries)
        if (entry.value > 0) entry.key: entry.value,
    });
    if (!mounted) return;
    if (success) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _busy = false;
      _error = _copy(context).stale;
    });
  }

  @override
  Widget build(BuildContext context) {
    final copy = _copy(context);
    final languageCode = Localizations.localeOf(context).languageCode;
    final pageStart = _page * _groupsPerPage;
    final pageGroups = widget.groups
        .skip(pageStart)
        .take(_groupsPerPage)
        .toList(growable: false);

    return Scaffold(
      key: const Key('kitchen_checket_handoff_sheet'),
      backgroundColor: PosSurfaceRole.background.fill,
      body: SafeArea(
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 12),
              decoration: const BoxDecoration(
                color: PosColors.surface,
                border: Border(bottom: BorderSide(color: PosColors.border)),
              ),
              child: Row(
                children: [
                  IconButton(
                    key: const Key('kitchen_checket_close'),
                    tooltip: copy.cancel,
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close_rounded),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      copy.title,
                      style: Theme.of(context).textTheme.headlineSmall
                          ?.copyWith(fontWeight: FontWeight.w900),
                    ),
                  ),
                  Text(
                    '${copy.selected} $_selectedTotal',
                    key: const Key('kitchen_checket_selected_total'),
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      color: PosColors.accent,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
            if (_error != null)
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 8,
                ),
                color: PosColors.danger.withValues(alpha: 0.1),
                child: Text(
                  _error!,
                  style: const TextStyle(
                    color: PosColors.danger,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                child: widget.groups.isEmpty
                    ? Center(
                        child: Text(
                          copy.empty,
                          style: Theme.of(context).textTheme.titleMedium,
                        ),
                      )
                    : Row(
                        key: const Key('kitchen_checket_three_columns'),
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          for (
                            var columnIndex = 0;
                            columnIndex < _columnCount;
                            columnIndex += 1
                          ) ...[
                            if (columnIndex > 0) const SizedBox(width: 10),
                            Expanded(
                              child: _KitchenChecketColumn(
                                columnIndex: columnIndex,
                                groups: pageGroups
                                    .skip(columnIndex * _groupsPerColumn)
                                    .take(_groupsPerColumn)
                                    .toList(growable: false),
                                selected: _selected,
                                languageCode: languageCode,
                                busy: _busy,
                                onChange: _change,
                              ),
                            ),
                          ],
                        ],
                      ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              decoration: const BoxDecoration(
                color: PosColors.surface,
                border: Border(top: BorderSide(color: PosColors.border)),
              ),
              child: Row(
                children: [
                  IconButton.outlined(
                    key: const Key('kitchen_checket_previous_page'),
                    tooltip: copy.previous,
                    onPressed: !_busy && _page > 0
                        ? () => setState(() => _page -= 1)
                        : null,
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: Text(
                      '${_page + 1} / $_pageCount',
                      key: const Key('kitchen_checket_page'),
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  IconButton.outlined(
                    key: const Key('kitchen_checket_next_page'),
                    tooltip: copy.next,
                    onPressed: !_busy && _page + 1 < _pageCount
                        ? () => setState(() => _page += 1)
                        : null,
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                  const Spacer(),
                  OutlinedButton(
                    onPressed: _busy ? null : () => Navigator.of(context).pop(),
                    child: Text(copy.cancel),
                  ),
                  const SizedBox(width: 10),
                  FilledButton.icon(
                    key: const Key('kitchen_checket_complete'),
                    onPressed: !_busy && _selectedTotal > 0 ? _submit : null,
                    icon: _busy
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.check_rounded),
                    label: Text('${copy.complete} · $_selectedTotal'),
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

class _KitchenChecketColumn extends StatelessWidget {
  const _KitchenChecketColumn({
    required this.columnIndex,
    required this.groups,
    required this.selected,
    required this.languageCode,
    required this.busy,
    required this.onChange,
  });

  final int columnIndex;
  final List<KitchenChecketMenuGroup> groups;
  final Map<String, int> selected;
  final String languageCode;
  final bool busy;
  final void Function(KitchenChecketMenuGroup group, int delta) onChange;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('kitchen_checket_column_$columnIndex'),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PosColors.border),
      ),
      child: Column(
        children: [
          for (var rowIndex = 0; rowIndex < 10; rowIndex += 1)
            Expanded(
              child: rowIndex < groups.length
                  ? _KitchenChecketRow(
                      group: groups[rowIndex],
                      selected: selected[groups[rowIndex].key] ?? 0,
                      languageCode: languageCode,
                      busy: busy,
                      onChange: (delta) => onChange(groups[rowIndex], delta),
                    )
                  : const SizedBox.shrink(),
            ),
        ],
      ),
    );
  }
}

class _KitchenChecketRow extends StatelessWidget {
  const _KitchenChecketRow({
    required this.group,
    required this.selected,
    required this.languageCode,
    required this.busy,
    required this.onChange,
  });

  final KitchenChecketMenuGroup group;
  final int selected;
  final String languageCode;
  final bool busy;
  final ValueChanged<int> onChange;

  @override
  Widget build(BuildContext context) {
    return Container(
      key: ValueKey('kitchen_checket_row_${group.key}'),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: PosColors.border)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              group.localizedName(languageCode),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontWeight: FontWeight.w800),
            ),
          ),
          IconButton(
            key: ValueKey('kitchen_checket_minus_${group.key}'),
            tooltip: '-',
            onPressed: !busy && selected > 0 ? () => onChange(-1) : null,
            icon: const Icon(Icons.remove_circle_outline_rounded),
          ),
          SizedBox(
            width: 54,
            child: Text(
              '$selected/${group.pendingQuantity}',
              key: ValueKey('kitchen_checket_progress_${group.key}'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontWeight: FontWeight.w900,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
          IconButton(
            key: ValueKey('kitchen_checket_plus_${group.key}'),
            tooltip: '+',
            onPressed: !busy && selected < group.pendingQuantity
                ? () => onChange(1)
                : null,
            icon: const Icon(Icons.add_circle_rounded),
          ),
        ],
      ),
    );
  }
}

({
  String title,
  String selected,
  String complete,
  String cancel,
  String previous,
  String next,
  String empty,
  String stale,
})
_copy(BuildContext context) =>
    switch (Localizations.localeOf(context).languageCode) {
      'vi' => (
        title: 'Chuyển checker',
        selected: 'Đã chọn',
        complete: 'Hoàn tất',
        cancel: 'Hủy',
        previous: 'Trang trước',
        next: 'Trang sau',
        empty: 'Không có món đang chờ hoàn tất.',
        stale: 'Số lượng đã thay đổi. Vui lòng mở lại danh sách.',
      ),
      'en' => (
        title: 'Checker handoff',
        selected: 'Selected',
        complete: 'Complete',
        cancel: 'Cancel',
        previous: 'Previous page',
        next: 'Next page',
        empty: 'No menu items are waiting for completion.',
        stale: 'Quantities changed. Reopen the list and try again.',
      ),
      _ => (
        title: 'checker 전달',
        selected: '선택',
        complete: '완료',
        cancel: '취소',
        previous: '이전 페이지',
        next: '다음 페이지',
        empty: '조리 완료 대기 메뉴가 없습니다.',
        stale: '수량이 변경되었습니다. 목록을 다시 열어 주세요.',
      ),
    };
