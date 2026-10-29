import 'package:flutter/material.dart';

import 'procurement_process_labels.dart';
import 'procurement_product_picker.dart';

class ProcurementAdjustmentDialog extends StatefulWidget {
  const ProcurementAdjustmentDialog({
    super.key,
    required this.lines,
    required this.products,
    required this.saveAdjustment,
    this.allowAdditions = false,
    this.loadCatalog,
    this.needsConfirmation,
    this.retrySavedAdjustment,
  });

  final List<Map<String, dynamic>> lines, products;
  final ProcurementCatalogLoader? loadCatalog;
  final Future<String?> Function(Map<String, dynamic>) saveAdjustment;
  final bool allowAdditions;
  final bool Function()? needsConfirmation;
  final Future<String?> Function()? retrySavedAdjustment;

  @override
  State<ProcurementAdjustmentDialog> createState() => _AdjustmentState();
}

class _AdjustmentLine {
  _AdjustmentLine(this.product, String quantity, this.unit, {this.existingId})
    : quantity = TextEditingController(text: quantity);
  final Map<String, dynamic> product;
  final String? existingId;
  final TextEditingController quantity;
  String unit;
}

class _AdjustmentState extends State<ProcurementAdjustmentDialog> {
  final _form = GlobalKey<FormState>();
  final _reason = TextEditingController();
  late final List<_AdjustmentLine> _lines;
  bool _saving = false, _confirmation = false;
  String? _error;

  String t(String ko, String en, String vi) =>
      switch (Localizations.localeOf(context).languageCode) {
        'ko' => ko,
        'vi' => vi,
        _ => en,
      };

  @override
  void initState() {
    super.initState();
    _lines = widget.lines
        .map(
          (l) => _AdjustmentLine(
            {
              'id': l['product_id'],
              'name': l['product_name'] ?? l['product_name_snapshot'],
            },
            l['requested_quantity'].toString(),
            l['requested_unit'].toString(),
            existingId: l['id'].toString(),
          ),
        )
        .toList();
  }

  @override
  void dispose() {
    _reason.dispose();
    for (final line in _lines) {
      line.quantity.dispose();
    }
    super.dispose();
  }

  Future<void> _add() async {
    final picked = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => ProcurementProductPicker(
        products: widget.products,
        loadCatalog: widget.loadCatalog,
      ),
    );
    if (!mounted || picked == null) return;
    final product = Map<String, dynamic>.from(picked['product'] as Map);
    if (_lines.any((l) => l.product['id'] == product['id'])) {
      setState(() {
        _error = t(
          '이미 포함된 품목입니다. 기존 수량을 조정하세요.',
          'This material is already included. Adjust its quantity.',
          'Nguyên liệu đã có. Hãy điều chỉnh số lượng.',
        );
      });
      return;
    }
    setState(() {
      _error = null;
      _lines.add(
        _AdjustmentLine(
          product,
          '1',
          (product['stock_unit'] ?? product['base_unit']).toString(),
        ),
      );
    });
  }

  Future<void> _save() async {
    if (!_confirmation && !_form.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final error = _confirmation
          ? await widget.retrySavedAdjustment!()
          : await widget.saveAdjustment({
              'reason': _reason.text.trim(),
              'lines': [
                for (final l in _lines.where((l) => l.existingId != null))
                  {
                    'request_line_id': l.existingId,
                    'quantity': l.quantity.text.trim(),
                  },
              ],
              if (widget.allowAdditions)
                'new_lines': [
                  for (final l in _lines.where((l) => l.existingId == null))
                    {
                      'product_id': l.product['id'],
                      'quantity': l.quantity.text.trim(),
                      'unit': l.unit,
                    },
                ],
            });
      if (!mounted) return;
      if (error == null) {
        Navigator.pop(context);
      } else {
        setState(() {
          _error = error;
          _confirmation = widget.needsConfirmation?.call() == true;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      procurementProcessLabel(
        'adjust_request',
        Localizations.localeOf(context).languageCode,
      ),
    ),
    content: SizedBox(
      width: 650,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null) Text(_error!),
              TextFormField(
                key: const Key('procurement_adjustment_reason'),
                controller: _reason,
                enabled: !_saving && !_confirmation,
                decoration: InputDecoration(
                  labelText: t(
                    '조정 사유',
                    'Adjustment reason',
                    'Lý do điều chỉnh',
                  ),
                ),
                validator: (v) => v == null || v.trim().isEmpty
                    ? t('필수 입력', 'Required', 'Bắt buộc')
                    : null,
              ),
              for (final line in _lines) ...[
                const SizedBox(height: 12),
                Text(line.product['name']?.toString() ?? ''),
                TextFormField(
                  key: ValueKey(
                    'adjustment_quantity_${line.existingId ?? line.product['id']}',
                  ),
                  controller: line.quantity,
                  enabled: !_saving && !_confirmation,
                  keyboardType: const TextInputType.numberWithOptions(
                    decimal: true,
                  ),
                  decoration: InputDecoration(
                    labelText: t('수량', 'Quantity', 'Số lượng'),
                    suffixText: line.existingId == null ? null : line.unit,
                  ),
                  validator: (v) {
                    final n = num.tryParse(v?.trim() ?? '');
                    return n == null ||
                            !n.isFinite ||
                            n <= 0 ||
                            n != num.parse(n.toStringAsFixed(3))
                        ? t('수량 확인', 'Check quantity', 'Kiểm tra số lượng')
                        : null;
                  },
                ),
                if (line.existingId == null)
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: line.unit,
                          items: [
                            for (final unit in {
                              line.product['base_unit'],
                              line.product['stock_unit'],
                            }.whereType<String>())
                              DropdownMenuItem(value: unit, child: Text(unit)),
                          ],
                          onChanged: _saving || _confirmation
                              ? null
                              : (v) => setState(() => line.unit = v!),
                        ),
                      ),
                      IconButton(
                        tooltip: t(
                          '추가 품목 제거',
                          'Remove added item',
                          'Xóa mục mới',
                        ),
                        onPressed: _saving || _confirmation
                            ? null
                            : () {
                                setState(() => _lines.remove(line));
                                line.quantity.dispose();
                              },
                        icon: const Icon(Icons.remove_circle_outline),
                      ),
                    ],
                  ),
              ],
              if (widget.allowAdditions)
                TextButton.icon(
                  key: const Key('procurement_adjustment_add'),
                  onPressed: _saving || _confirmation || _lines.length >= 200
                      ? null
                      : _add,
                  icon: const Icon(Icons.add),
                  label: Text(t('품목 추가', 'Add item', 'Thêm mặt hàng')),
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: Text(t('취소', 'Cancel', 'Hủy')),
      ),
      FilledButton(
        key: const Key('procurement_adjustment_save'),
        onPressed: _saving ? null : _save,
        child: Text(
          _confirmation
              ? t(
                  '저장 결과 확인',
                  'Confirm saved adjustment',
                  'Xác nhận kết quả lưu',
                )
              : t('저장', 'Save', 'Lưu'),
        ),
      ),
    ],
  );
}
