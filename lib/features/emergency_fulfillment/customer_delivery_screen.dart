import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/ui/pos_design_tokens.dart';
import 'emergency_fulfillment_provider.dart';

typedef CustomerDeliverySubmit =
    Future<bool> Function(List<CustomerDeliveryAllocation> allocations);

class CustomerDeliveryScreen extends StatefulWidget {
  const CustomerDeliveryScreen({
    super.key,
    required this.floorLabel,
    required this.boxes,
    required this.onSubmit,
  });

  final String floorLabel;
  final List<CustomerDeliveryBox> boxes;
  final CustomerDeliverySubmit onSubmit;

  @override
  State<CustomerDeliveryScreen> createState() => _CustomerDeliveryScreenState();
}

class _CustomerDeliveryScreenState extends State<CustomerDeliveryScreen> {
  static const _pageSize = 8;

  final Map<String, int> _selected = {};
  int _page = 0;
  bool _busy = false;
  String? _error;

  int get _pageCount => math.max(1, (widget.boxes.length / _pageSize).ceil());

  List<CustomerDeliveryBox> get _pageBoxes => widget.boxes
      .skip(_page * _pageSize)
      .take(_pageSize)
      .toList(growable: false);

  int get _selectedTotal =>
      _selected.values.fold(0, (total, quantity) => total + quantity);

  void _change(CustomerDeliveryMenu menu, int delta) {
    if (_busy) return;
    final current = _selected[menu.key] ?? 0;
    final next = (current + delta).clamp(0, menu.availableQuantity);
    setState(() {
      if (next == 0) {
        _selected.remove(menu.key);
      } else {
        _selected[menu.key] = next;
      }
      _error = null;
    });
  }

  Future<void> _submit() async {
    if (_busy || _selectedTotal <= 0) return;
    List<CustomerDeliveryAllocation> allocations;
    try {
      allocations = allocateCustomerDeliverySelections(_pageBoxes, _selected);
    } catch (_) {
      setState(() => _error = _copy(context).stale);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    final success = await widget.onSubmit(allocations);
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
    final landscape =
        MediaQuery.orientationOf(context) == Orientation.landscape;
    final columns = landscape ? 4 : 2;
    final firstIndex = _page * _pageSize;
    return Scaffold(
      key: const Key('customer_delivery_screen'),
      backgroundColor: PosSurfaceRole.background.fill,
      appBar: AppBar(
        leading: IconButton(
          key: const Key('customer_delivery_close'),
          onPressed: _busy ? null : () => Navigator.of(context).pop(),
          icon: const Icon(Icons.close_rounded),
        ),
        title: Text('${widget.floorLabel} · ${copy.title}'),
      ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  key: const Key('customer_delivery_error'),
                  style: const TextStyle(
                    color: PosColors.danger,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  const spacing = 10.0;
                  final rows = _pageSize ~/ columns;
                  final cellWidth =
                      (constraints.maxWidth - spacing * (columns - 1)) /
                      columns;
                  final cellHeight =
                      (constraints.maxHeight - spacing * (rows - 1)) / rows;
                  return GridView.builder(
                    key: const Key('customer_delivery_grid_8_slots'),
                    physics: const NeverScrollableScrollPhysics(),
                    itemCount: _pageSize,
                    gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: columns,
                      crossAxisSpacing: spacing,
                      mainAxisSpacing: spacing,
                      childAspectRatio: cellWidth / math.max(1, cellHeight),
                    ),
                    itemBuilder: (context, slot) {
                      final index = firstIndex + slot;
                      if (index >= widget.boxes.length) {
                        return Container(
                          key: ValueKey('customer_delivery_empty_slot_$slot'),
                          decoration: BoxDecoration(
                            color: PosColors.surface.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(color: PosColors.border),
                          ),
                        );
                      }
                      return _CustomerDeliveryOrderBox(
                        box: widget.boxes[index],
                        selected: _selected,
                        busy: _busy,
                        copy: copy,
                        onChange: _change,
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: const BoxDecoration(
            color: PosColors.surface,
            border: Border(top: BorderSide(color: PosColors.border)),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final pager = Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton.outlined(
                    key: const Key('customer_delivery_previous_page'),
                    tooltip: copy.previous,
                    onPressed: !_busy && _selectedTotal == 0 && _page > 0
                        ? () => setState(() => _page -= 1)
                        : null,
                    icon: const Icon(Icons.chevron_left_rounded),
                  ),
                  SizedBox(
                    width: 86,
                    child: Text(
                      '${_page + 1} / $_pageCount',
                      key: const Key('customer_delivery_page'),
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontWeight: FontWeight.w900),
                    ),
                  ),
                  IconButton.outlined(
                    key: const Key('customer_delivery_next_page'),
                    tooltip: copy.next,
                    onPressed:
                        !_busy && _selectedTotal == 0 && _page + 1 < _pageCount
                        ? () => setState(() => _page += 1)
                        : null,
                    icon: const Icon(Icons.chevron_right_rounded),
                  ),
                ],
              );
              final complete = FilledButton.icon(
                key: const Key('customer_delivery_complete'),
                onPressed: !_busy && _selectedTotal > 0 ? _submit : null,
                icon: _busy
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.room_service_rounded),
                label: Text('${copy.complete} · $_selectedTotal'),
                style: FilledButton.styleFrom(minimumSize: const Size(210, 56)),
              );
              if (constraints.maxWidth < 560) {
                return Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Align(alignment: Alignment.center, child: pager),
                    const SizedBox(height: 8),
                    complete,
                  ],
                );
              }
              return Row(children: [pager, const Spacer(), complete]);
            },
          ),
        ),
      ),
    );
  }
}

class _CustomerDeliveryOrderBox extends StatelessWidget {
  const _CustomerDeliveryOrderBox({
    required this.box,
    required this.selected,
    required this.busy,
    required this.copy,
    required this.onChange,
  });

  final CustomerDeliveryBox box;
  final Map<String, int> selected;
  final bool busy;
  final _CustomerDeliveryCopy copy;
  final void Function(CustomerDeliveryMenu menu, int delta) onChange;

  @override
  Widget build(BuildContext context) {
    final languageCode = Localizations.localeOf(context).languageCode;
    return Container(
      key: ValueKey('customer_delivery_box_${box.queueId}'),
      decoration: BoxDecoration(
        color: PosColors.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: PosColors.border, width: 2),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: const Color(0xFF7B1FA2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Text(
              '${copy.table} ${box.tableNumber}',
              key: ValueKey('customer_delivery_table_${box.queueId}'),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: Theme.of(context).textTheme.titleLarge?.copyWith(
                color: Colors.white,
                fontWeight: FontWeight.w900,
              ),
            ),
          ),
          Expanded(
            child: ListView.separated(
              padding: const EdgeInsets.all(8),
              itemCount: box.menus.length,
              separatorBuilder: (_, _) => const Divider(height: 8),
              itemBuilder: (context, index) {
                final menu = box.menus[index];
                final quantity = selected[menu.key] ?? 0;
                return Row(
                  key: ValueKey('customer_delivery_menu_${menu.key}'),
                  children: [
                    Expanded(
                      child: Text(
                        menu.localizedName(languageCode),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                    ),
                    IconButton(
                      key: ValueKey('customer_delivery_minus_${menu.key}'),
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      onPressed: !busy && quantity > 0
                          ? () => onChange(menu, -1)
                          : null,
                      icon: const Icon(Icons.remove_circle_outline_rounded),
                    ),
                    SizedBox(
                      width: 46,
                      child: Text(
                        '$quantity/${menu.availableQuantity}',
                        key: ValueKey('customer_delivery_progress_${menu.key}'),
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontWeight: FontWeight.w900),
                      ),
                    ),
                    IconButton(
                      key: ValueKey('customer_delivery_plus_${menu.key}'),
                      constraints: const BoxConstraints.tightFor(
                        width: 48,
                        height: 48,
                      ),
                      onPressed: !busy && quantity < menu.availableQuantity
                          ? () => onChange(menu, 1)
                          : null,
                      icon: const Icon(Icons.add_circle_rounded),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _CustomerDeliveryCopy {
  const _CustomerDeliveryCopy(this.languageCode);

  final String languageCode;

  String _pick(String ko, String vi, String en) => switch (languageCode) {
    'vi' => vi,
    'en' => en,
    _ => ko,
  };

  String get title => _pick('고객전달', 'Giao khách', 'Customer delivery');
  String get table => _pick('테이블', 'Bàn', 'Table');
  String get complete =>
      _pick('고객전달완료', 'Hoàn tất giao khách', 'Complete delivery');
  String get previous => _pick('이전 페이지', 'Trang trước', 'Previous page');
  String get next => _pick('다음 페이지', 'Trang sau', 'Next page');
  String get stale => _pick(
    '전달 가능 수량이 변경되었습니다. 닫은 뒤 다시 열어 주세요.',
    'Số lượng có thể giao đã thay đổi. Hãy đóng và mở lại.',
    'Available quantities changed. Close and reopen this screen.',
  );
}

_CustomerDeliveryCopy _copy(BuildContext context) =>
    _CustomerDeliveryCopy(Localizations.localeOf(context).languageCode);
