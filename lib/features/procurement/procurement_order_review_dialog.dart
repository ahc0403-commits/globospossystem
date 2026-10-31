import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../core/services/pos_backend.dart';
import 'inventory_lot_workspace.dart' show InventoryLotRpc;

/// Reviews the immutable PO contract and records an explicit administrator action.
class ProcurementOrderReviewDialog extends StatefulWidget {
  const ProcurementOrderReviewDialog({
    super.key,
    required this.storeId,
    required this.orderId,
    required this.accounting,
    this.call,
  });
  final String storeId, orderId;
  final bool accounting;
  final InventoryLotRpc? call;
  @override
  State<ProcurementOrderReviewDialog> createState() =>
      _ProcurementOrderReviewDialogState();
}

class _ProcurementOrderReviewDialogState
    extends State<ProcurementOrderReviewDialog> {
  final _form = GlobalKey<FormState>();
  List<Map<String, dynamic>> _rows = [];
  final _values = <String, String>{};
  bool _busy = true;
  String? _error, _line, _pendingMethod;
  Map<String, dynamic>? _pending;
  String t(String ko, String en, String vi) =>
      switch (Localizations.localeOf(context).languageCode) {
        'ko' => ko,
        'vi' => vi,
        _ => en,
      };
  Future<dynamic> call(String n, Map<String, dynamic> p) =>
      widget.call?.call(n, p) ?? supabase.rpc(n, params: p);
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final result = await call(
        widget.accounting
            ? 'get_procurement_reconciliation_source_v1'
            : 'admin_get_order_quality_review_v1',
        {
          'p_store': widget.storeId,
          if (widget.accounting)
            'p_orders': [widget.orderId]
          else
            'p_order': widget.orderId,
        },
      );
      if (mounted) {
        setState(
          () => _rows = (result as List)
              .map((r) => Map<String, dynamic>.from(r as Map))
              .toList(),
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = t(
            '검토 자료를 불러오지 못했습니다.',
            'Could not load review data.',
            'Không tải được dữ liệu đối chiếu.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    if (_pending == null) {
      if (!_form.currentState!.validate()) return;
      if (widget.accounting) {
        _pendingMethod = 'admin_record_procurement_reconciliation_v1';
        _pending = {
          'p_id': const Uuid().v4(),
          'p_store': widget.storeId,
          'p_order': widget.orderId,
          'p_source_hash': _rows.single['source_hash'],
          'p_payload': {
            'currency': 'VND',
            'invoice_ids': (_values['invoice_ids'] ?? '')
                .split(',')
                .map((s) => s.trim())
                .where((s) => s.isNotEmpty)
                .toList(),
            'office_reference': _values['office_reference']!.trim(),
            for (final key in [
              'invoice_amount',
              'credit_amount',
              'paid_amount',
            ])
              key: num.parse(_values[key]!),
          },
        };
      } else {
        final row = _rows.firstWhere((r) => r['line_id'] == _line);
        _pendingMethod = 'admin_amend_order_quality_v1';
        _pending = {
          'p_id': const Uuid().v4(),
          'p_line': _line,
          'p_profile': (row['latest'] as Map)['id'],
          'p_reason': _values['reason']!.trim(),
        };
      }
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await call(_pendingMethod!, _pending!);
      if (mounted) Navigator.pop(context, result);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = t(
            '저장 결과를 확인하지 못했습니다. 같은 요청으로 재확인하거나 닫은 뒤 최신 자료를 확인하세요.',
            'Save was not confirmed. Retry this request or close and review the latest data.',
            'Chưa xác nhận lưu. Thử lại cùng yêu cầu hoặc đóng và kiểm tra dữ liệu mới.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Widget field(
    String key,
    String label, {
    bool amount = false,
    bool required = true,
  }) => TextFormField(
    key: ValueKey(key),
    enabled: !_busy && _pending == null,
    decoration: InputDecoration(labelText: label),
    keyboardType: amount
        ? const TextInputType.numberWithOptions(decimal: true)
        : TextInputType.text,
    onChanged: (v) => _values[key] = v,
    validator: (v) {
      if (amount) {
        final n = num.tryParse(v ?? '');
        return n != null &&
                n.isFinite &&
                n >= 0 &&
                n * 100 == (n * 100).roundToDouble()
            ? null
            : '*';
      }
      return !required || (v ?? '').trim().length >= 5 ? null : '*';
    },
  );
  Widget criteria(Map c) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        '${t('온도', 'Temperature', 'Nhiệt độ')}: ${c['temperature_required'] == true ? '${c['temperature_min_c']}–${c['temperature_max_c']} °C' : t('비대상', 'Not applicable', 'Không áp dụng')}',
      ),
      Text(
        '${t('최소 잔여 일수', 'Minimum remaining days', 'Số ngày còn lại tối thiểu')}: ${c['expiry_required'] == true ? c['min_remaining_days'] : t('비대상', 'Not applicable', 'Không áp dụng')}',
      ),
      Text('${t('표본 수', 'Sample count', 'Số mẫu')}: ${c['min_sample_count']}'),
      Text(
        '${t('사진 필수', 'Photo required', 'Bắt buộc ảnh')}: ${c['photo_required'] == true} · ${t('로트 필수', 'Lot required', 'Bắt buộc lô')}: ${c['lot_required'] == true}',
      ),
    ],
  );
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      widget.accounting
          ? t(
              'Office 대사 증거',
              'Office reconciliation evidence',
              'Bằng chứng đối chiếu Office',
            )
          : t(
              '발주 검수 기준 변경',
              'Amend PO inspection criteria',
              'Đổi tiêu chí kiểm tra đơn mua',
            ),
    ),
    content: SizedBox(
      width: 640,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (_busy) const LinearProgressIndicator(),
              if (_error != null) Text(_error!),
              if (widget.accounting && _rows.isNotEmpty) ...[
                Text(
                  '${(_rows.single['identity'] as Map)['store_name']} · ${(_rows.single['identity'] as Map)['store_code'] ?? '—'}',
                ),
                SelectableText(
                  '${t('매장 ID', 'Store ID', 'ID cửa hàng')}: ${widget.storeId}\n${t('법인 ID', 'Legal entity ID', 'ID pháp nhân')}: ${(_rows.single['identity'] as Map)['tax_entity_id']}',
                ),
                Text(
                  '${t('확정 입고 금액', 'Confirmed receipts', 'Tiền nhập đã xác nhận')}: ${_rows.single['expected_gross']} VND\n${t('반품 credit', 'Return credit', 'Credit trả hàng')}: ${_rows.single['expected_credit']} VND',
                ),
                Text(
                  t(
                    'Office에서 확인한 실제 값을 입력합니다. 증거 저장은 지급을 실행하지 않습니다.',
                    'Enter the actual values verified in Office. Saving evidence does not execute a payment.',
                    'Nhập giá trị đã xác minh tại Office. Lưu bằng chứng không thực hiện thanh toán.',
                  ),
                ),
                field(
                  'invoice_ids',
                  t(
                    '외부 송장 ID (쉼표 구분)',
                    'External invoice IDs (comma separated)',
                    'ID hóa đơn ngoài (cách bằng dấu phẩy)',
                  ),
                  required: false,
                ),
                field(
                  'invoice_amount',
                  t('외부 송장 합계', 'External invoice total', 'Tổng hóa đơn ngoài'),
                  amount: true,
                ),
                field(
                  'credit_amount',
                  t(
                    '외부 credit 합계',
                    'External credit total',
                    'Tổng credit ngoài',
                  ),
                  amount: true,
                ),
                field(
                  'paid_amount',
                  t(
                    '확인된 지급 합계',
                    'Verified paid total',
                    'Tổng đã thanh toán xác minh',
                  ),
                  amount: true,
                ),
                field(
                  'office_reference',
                  t(
                    'Office 대사 참조·증거',
                    'Office reconciliation reference/evidence',
                    'Tham chiếu/bằng chứng đối chiếu Office',
                  ),
                ),
              ],
              if (!widget.accounting) ...[
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: t('발주 품목', 'PO item', 'Mặt hàng đơn mua'),
                  ),
                  items: [
                    for (final row in _rows)
                      if (row['latest'] != null &&
                          (row['latest'] as Map)['id'] !=
                              (row['current'] as Map)['profile_id'])
                        DropdownMenuItem(
                          value: row['line_id'].toString(),
                          child: Text(row['product_name'].toString()),
                        ),
                  ],
                  onChanged: _pending != null
                      ? null
                      : (v) => setState(() => _line = v),
                  validator: (v) => v == null ? '*' : null,
                ),
                if (_line != null) ...[
                  for (final row in _rows.where(
                    (r) => r['line_id'] == _line,
                  )) ...[
                    Text(
                      '${t('현재 기준', 'Current criteria', 'Tiêu chí hiện tại')} v${(row['current'] as Map)['revision']}',
                    ),
                    criteria((row['current'] as Map)['criteria'] as Map),
                    const Divider(),
                    Text(
                      '${t('변경할 승인 기준', 'Approved replacement', 'Tiêu chí đã duyệt thay thế')} v${(row['latest'] as Map)['revision']}',
                    ),
                    criteria((row['latest'] as Map)['criteria'] as Map),
                  ],
                  Text(
                    t(
                      '변경 후 새 검수부터 적용하며 기존 입고 기록은 보존합니다.',
                      'Applies to subsequent inspections; existing receipt evidence is preserved.',
                      'Áp dụng cho kiểm tra mới; giữ nguyên bằng chứng nhập trước.',
                    ),
                  ),
                ],
                field(
                  'reason',
                  t(
                    '변경 사유 (5자 이상)',
                    'Reason (at least 5 characters)',
                    'Lý do (ít nhất 5 ký tự)',
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: Text(t('닫기', 'Close', 'Đóng')),
      ),
      FilledButton(
        onPressed: _busy || _rows.isEmpty ? null : _save,
        child: Text(
          _pending != null
              ? t('같은 요청 재확인', 'Retry same request', 'Thử lại cùng yêu cầu')
              : t('증거 저장', 'Save evidence', 'Lưu bằng chứng'),
        ),
      ),
    ],
  );
}
