import 'package:flutter/material.dart';

/// Shares the inspected lot quantities with the receipt/count form. Locations
/// refer to inventory storage, never to dining floors or kitchen stations.
class InventoryLotEditor extends StatefulWidget {
  const InventoryLotEditor({
    super.key,
    required this.lots,
    required this.locations,
    required this.onChanged,
    this.countMode = false,
  });
  final List<Map<String, dynamic>> lots, locations;
  final VoidCallback onChanged;
  final bool countMode;
  @override
  State<InventoryLotEditor> createState() => _InventoryLotEditorState();
}

class _InventoryLotEditorState extends State<InventoryLotEditor> {
  String t(String ko, String en, String vi) =>
      switch (Localizations.localeOf(context).languageCode) {
        'ko' => ko,
        'vi' => vi,
        _ => en,
      };
  void changed(VoidCallback change) {
    setState(change);
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        t('로트별 실물 수량', 'Physical quantities by lot', 'Số lượng thực theo lô'),
      ),
      for (final lot in widget.lots)
        Card(
          key: ObjectKey(lot),
          child: Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              children: [
                TextFormField(
                  initialValue: lot['code']?.toString() ?? '',
                  readOnly: lot['id'] != null,
                  decoration: InputDecoration(
                    labelText: t('공급업체 로트', 'Supplier lot', 'Lô nhà cung cấp'),
                  ),
                  onChanged: (v) => lot['code'] = v.trim(),
                  validator: (v) =>
                      !widget.countMode && (v?.trim().isEmpty ?? true)
                      ? '*'
                      : null,
                ),
                TextFormField(
                  initialValue: lot['expiry_date']?.toString() ?? '',
                  readOnly: lot['id'] != null,
                  decoration: InputDecoration(
                    labelText: t(
                      '유통기한 (YYYY-MM-DD)',
                      'Lot expiry (YYYY-MM-DD)',
                      'Hạn dùng lô (YYYY-MM-DD)',
                    ),
                  ),
                  onChanged: (v) => lot['expiry_date'] = v.trim(),
                  validator: (v) =>
                      v == null ||
                          v.isEmpty ||
                          (DateTime.tryParse(
                                v,
                              )?.toIso8601String().substring(0, 10) ==
                              v)
                      ? null
                      : 'YYYY-MM-DD',
                ),
                for (final field
                    in widget.countMode
                        ? ['quantity_base']
                        : ['accepted', 'held', 'rejected']) ...[
                  TextFormField(
                    initialValue: (lot[field] ?? 0).toString(),
                    decoration: InputDecoration(
                      labelText: switch (field) {
                        'held' => t('보류', 'Held', 'Tạm giữ'),
                        'rejected' => t('불합격', 'Rejected', 'Không đạt'),
                        'quantity_base' => t(
                          '실사 수량 (기준 단위)',
                          'Counted quantity (base units)',
                          'Số lượng kiểm kê (đơn vị cơ sở)',
                        ),
                        _ => t('합격', 'Accepted', 'Đạt'),
                      },
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (v) =>
                        changed(() => lot[field] = num.tryParse(v)),
                    validator: (v) {
                      final n = num.tryParse(v ?? '');
                      return n != null &&
                              n.isFinite &&
                              n >= 0 &&
                              (n * 1000 - (n * 1000).round()).abs() < 0.00001
                          ? null
                          : '*';
                    },
                  ),
                  if ((lot[field] as num? ?? 0) > 0)
                    DropdownButtonFormField<String>(
                      initialValue:
                          lot[switch (field) {
                                'held' => 'held_location_id',
                                'rejected' => 'rejected_location_id',
                                _ => 'location_id',
                              }]
                              as String?,
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: t(
                          '보관 위치',
                          'Storage location',
                          'Vị trí lưu trữ',
                        ),
                      ),
                      items: [
                        for (final loc in widget.locations)
                          if (loc['kind'] ==
                              switch (field) {
                                'held' => 'quarantine',
                                'rejected' => 'rejected',
                                _ => 'storage',
                              })
                            DropdownMenuItem(
                              value: loc['id'].toString(),
                              child: Text(loc['name'].toString()),
                            ),
                      ],
                      onChanged: lot['id'] != null
                          ? null
                          : (v) =>
                                lot[switch (field) {
                                      'held' => 'held_location_id',
                                      'rejected' => 'rejected_location_id',
                                      _ => 'location_id',
                                    }] =
                                    v,
                      validator: (v) => v == null ? '*' : null,
                    ),
                ],
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    onPressed: () => changed(() => widget.lots.remove(lot)),
                    icon: const Icon(Icons.remove_circle_outline),
                    label: Text(t('제거', 'Remove', 'Xóa')),
                  ),
                ),
              ],
            ),
          ),
        ),
      TextButton.icon(
        onPressed: widget.lots.length >= (widget.countMode ? 100 : 20)
            ? null
            : () => changed(
                () => widget.lots.add({
                  'code': '',
                  'expiry_date': '',
                  if (widget.countMode)
                    'quantity_base': 0
                  else ...{
                    'accepted': 0,
                    'held': 0,
                    'rejected': 0,
                  },
                }),
              ),
        icon: const Icon(Icons.add),
        label: Text(t('로트 추가', 'Add lot', 'Thêm lô')),
      ),
    ],
  );
}
