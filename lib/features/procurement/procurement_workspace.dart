import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

typedef ProcurementLoad = Future<Map<String, dynamic>> Function();
typedef ProcurementExecute =
    Future<Map<String, dynamic>> Function(
      String action,
      String? recordId,
      int version,
      String key,
      Map<String, dynamic> payload,
    );

/// The API owns transitions; this page only presents the actions it returns.
class ProcurementWorkspacePage extends StatefulWidget {
  const ProcurementWorkspacePage({
    super.key,
    required this.load,
    required this.execute,
    this.onOpenOrder,
    this.openEvidence,
  });
  final Future<void> Function(String receiptId, String path)? openEvidence;
  final ProcurementLoad load;
  final ProcurementExecute execute;
  final ValueChanged<String>? onOpenOrder;
  @override
  State<ProcurementWorkspacePage> createState() =>
      _ProcurementWorkspacePageState();
}

class _ProcurementWorkspacePageState extends State<ProcurementWorkspacePage> {
  Map<String, dynamic> _data = {};
  Map<String, dynamic>? _pending;
  String? _selectedId, _error, _journalKey;
  bool _loading = true, _busy = false;
  int _generation = 0;
  String t(String ko, String en, String vi) =>
      switch (Localizations.localeOf(context).languageCode) {
        'ko' => ko,
        'vi' => vi,
        _ => en,
      };
  List<Map<String, dynamic>> rows(dynamic value) => value is List
      ? value.whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList()
      : [];
  Map<String, dynamic> map(dynamic value) =>
      value is Map ? Map<String, dynamic>.from(value) : {};
  bool get enabled => _data['enabled'] == true;
  Map<String, dynamic> get actor => map(_data['actor']);
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final generation = ++_generation;
    if (mounted) setState(() => _loading = true);
    try {
      final data = await widget.load();
      if (data['contract_version'] != 2) {
        throw StateError('PROCUREMENT_CONTRACT_NOT_READY');
      }
      final identity = map(data['actor']);
      final key =
          'procurement.command.${identity['system']}.${identity['subject_id']}.${data['store_id']}';
      final raw = (await SharedPreferences.getInstance()).getString(key);
      final pending = raw == null ? null : map(jsonDecode(raw));
      if (!mounted || generation != _generation) return;
      setState(() {
        _data = data;
        _journalKey = key;
        _pending = pending;
        _loading = false;
        _error = null;
      });
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = _errorText(e);
        });
      }
    }
  }

  String _errorText(Object e) {
    final code = RegExp(
      r'(?:PROCUREMENT|INVENTORY)_[A-Z_]+',
    ).firstMatch(e.toString())?.group(0);
    if (code == 'PROCUREMENT_CONTRACT_NOT_READY' ||
        code == 'PROCUREMENT_NOT_ENABLED') {
      return t(
        '이 매장의 구매 기능 설정이 필요합니다.',
        'Procurement setup is required for this store.',
        'Cần thiết lập mua hàng cho cửa hàng này.',
      );
    }
    if (code == 'PROCUREMENT_STALE_VERSION') {
      return t(
        '다른 담당자가 변경했습니다. 새로고침 후 다시 확인하세요.',
        'This record changed. Refresh and review it again.',
        'Dữ liệu đã thay đổi. Hãy tải lại và kiểm tra.',
      );
    }
    return '${t('처리하지 못했습니다. 입력과 현재 상태를 확인하세요.', 'The action could not be completed. Check the input and current status.', 'Không thể hoàn tất. Kiểm tra dữ liệu và trạng thái.')} ${code ?? ''}';
  }

  Future<void> _execute(
    String action,
    Map<String, dynamic>? record,
    Map<String, dynamic> payload,
  ) async {
    if (_busy || _pending != null || _journalKey == null) return;
    final pending = {
      'action': action,
      'record_id': record?['id'],
      'version': record?['row_version'] ?? 0,
      'key': const Uuid().v4(),
      'payload': payload,
    };
    setState(() => _busy = true);
    try {
      final prefs = await SharedPreferences.getInstance();
      if (!await prefs.setString(_journalKey!, jsonEncode(pending))) {
        throw StateError('Could not save retry record');
      }
      if (!mounted) return;
      setState(() => _pending = pending);
      await _sendPending();
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendPending() async {
    final p = _pending;
    if (p == null) return;
    try {
      await widget.execute(
        p['action'] as String,
        p['record_id'] as String?,
        (p['version'] as num).toInt(),
        p['key'] as String,
        map(p['payload']),
      );
    } catch (error) {
      // These codes are explicit transactional rejections, not uncertain transport failures.
      final code =
          RegExp(
            r'PROCUREMENT_[A-Z_]+',
          ).firstMatch(error.toString())?.group(0) ??
          (RegExp(r'code: (22|23)[A-Z0-9]{3}').hasMatch(error.toString())
              ? 'PROCUREMENT_INPUT_INVALID'
              : null);
      if (code != null &&
          !const {
            'PROCUREMENT_OPERATION_FAILED',
            'PROCUREMENT_CONTRACT_NOT_READY',
          }.contains(code)) {
        await (await SharedPreferences.getInstance()).remove(_journalKey!);
        if (mounted) {
          setState(() => _pending = null);
          await _load();
        }
      }
      rethrow;
    }
    await (await SharedPreferences.getInstance()).remove(_journalKey!);
    if (!mounted) return;
    setState(() => _pending = null);
    await _load();
  }

  Future<void> _retry() async {
    setState(() => _busy = true);
    try {
      await _sendPending();
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String label(String action) => switch (action) {
    'return_goods' => t('공급업체 반품', 'Supplier return', 'Trả nhà cung cấp'),
    'cancel_remaining' => t(
      '미입고 잔량 취소',
      'Remainder cancellation',
      'Hủy phần chưa nhận',
    ),
    'resolve_issue' => t(
      '입고 차이 처리',
      'Receipt issue resolved',
      'Xử lý chênh lệch',
    ),
    'amend_po' => t('변경 구매요청', 'Purchase amendment', 'Yêu cầu sửa mua hàng'),
    'create_request' => t('요청 작성', 'Request created', 'Tạo yêu cầu'),
    'configure' => t('구매 정책 변경', 'Policy updated', 'Cập nhật chính sách'),
    'cancelled' => t('취소', 'Cancelled', 'Đã hủy'),
    'draft' => t('작성 중', 'Draft', 'Bản nháp'),
    'submitted' => t('매장 검토 대기', 'Store review', 'Chờ cửa hàng duyệt'),
    'office_review' => t('Office 검토', 'Office review', 'Văn phòng xem xét'),
    'senior_review' => t('추가 승인 대기', 'Senior approval', 'Chờ duyệt cấp cao'),
    'approved' => t('승인 완료', 'Approved', 'Đã duyệt'),
    'allocated' => t('발주서 생성 완료', 'POs created', 'Đã tạo đơn mua'),
    'returned' => t('수정 요청', 'Returned', 'Yêu cầu sửa'),
    'issued' => t('PO 발행', 'Issued', 'Đã phát hành'),
    'sent' => t('업체 전달', 'Sent', 'Đã gửi'),
    'confirmed' => t('업체 확인', 'Confirmed', 'Đã xác nhận'),
    'save_request' => t('수정', 'Edit', 'Sửa'),
    'submit_request' => t('제출', 'Submit', 'Gửi'),
    'store_approve' => t('매장 승인', 'Approve request', 'Duyệt yêu cầu'),
    'return_request' => t('반려', 'Return', 'Trả lại'),
    'office_approve' => t('구매 승인', 'Approve purchase', 'Duyệt mua hàng'),
    'senior_approve' => t('상위 승인', 'Senior approval', 'Duyệt cấp cao'),
    'save_quote' => t('견적 추가', 'Add quote', 'Thêm báo giá'),
    'select_quote' => t('견적 선택', 'Select quote', 'Chọn báo giá'),
    'issue_po' => t('PO 발행', 'Issue PO', 'Phát hành đơn mua'),
    'send_po' => t('전달 기록', 'Record sending', 'Ghi nhận đã gửi'),
    'confirm_po' => t(
      '업체 확인 기록',
      'Confirm supplier terms',
      'Xác nhận điều kiện',
    ),
    _ => action,
  };
  Future<void> _editRequest([Map<String, dynamic>? request]) async {
    final payload = await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (c) => ProcurementRequestDialog(
        products: rows(_data['products']),
        supplierItems: rows(_data['supplier_items']),
        initial: request,
      ),
    );
    if (payload != null && mounted) {
      await _execute(
        request == null ? 'create_request' : 'save_request',
        request,
        payload,
      );
    }
  }

  Future<Map<String, dynamic>?> _fields(
    String title,
    Map<String, String> fields, {
    Map<String, String> initial = const {},
  }) async {
    return showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (c) => ProcurementFieldsDialog(
        title: title,
        fields: fields,
        initial: initial,
      ),
    );
  }

  Future<void> _action(String action, Map<String, dynamic> request) async {
    if (action == 'save_request') {
      await _editRequest(request);
      return;
    }
    if (action == 'return_request') {
      final value = await _fields(label(action), {
        'reason': t('반려 사유', 'Reason', 'Lý do'),
      });
      if (value != null) await _execute(action, request, value);
      return;
    }
    final accepted = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(label(action)),
        content: Text(
          '${request['request_no'] ?? request['purchase_order_no']}\n${request['reason'] ?? ''}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: Text(t('취소', 'Cancel', 'Hủy')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: Text(label(action)),
          ),
        ],
      ),
    );
    if (accepted == true) await _execute(action, request, {});
  }

  Future<void> _configure() async {
    final policy = map(_data['policy']);
    final p = await _fields(
      t('구매 정책 설정', 'Purchase policy', 'Chính sách mua hàng'),
      {
        'high_value_amount': t(
          '추가 승인 기준 금액',
          'Senior approval amount',
          'Số tiền cần duyệt cấp cao',
        ),
        'quantity_review_multiplier': t(
          '평균 입고량 대비 추가 승인 배수',
          'Quantity escalation multiplier',
          'Hệ số lượng cần duyệt thêm',
        ),
        'max_price_increase_percent': t(
          '가격 상승 검토 기준 (%)',
          'Price increase threshold (%)',
          'Ngưỡng tăng giá (%)',
        ),
      },
      initial: {
        'high_value_amount': '${policy['high_value_amount'] ?? ''}',
        'quantity_review_multiplier':
            '${policy['quantity_review_multiplier'] ?? ''}',
        'max_price_increase_percent':
            '${policy['max_price_increase_percent'] ?? ''}',
      },
    );
    if (p == null) return;
    final quantityMultiplier = double.tryParse(
      p['quantity_review_multiplier'].toString(),
    );
    if (quantityMultiplier == null ||
        !quantityMultiplier.isFinite ||
        quantityMultiplier < 1) {
      setState(
        () => _error = t(
          '수량 승인 배수는 1 이상이어야 합니다.',
          'Quantity multiplier must be at least 1.',
          'Hệ số lượng phải từ 1 trở lên.',
        ),
      );
      return;
    }

    final amount = double.tryParse(p['high_value_amount'] as String),
        percent = double.tryParse(p['max_price_increase_percent'] as String);
    if (amount == null ||
        !amount.isFinite ||
        amount <= 0 ||
        percent == null ||
        !percent.isFinite ||
        percent < 0) {
      setState(
        () => _error = t(
          '유효한 금액과 비율을 입력하세요.',
          'Enter a valid amount and percentage.',
          'Nhập số tiền và tỷ lệ hợp lệ.',
        ),
      );
      return;
    }
    await _execute('configure', policy.isEmpty ? null : policy, {
      'enabled': true,
      'quantity_review_multiplier': quantityMultiplier,
      'high_value_amount': amount,
      'max_price_increase_percent': percent,
      'stock_freshness_hours': policy['stock_freshness_hours'] ?? 24,
    });
  }

  Widget _receiptCard(Map<String, dynamic> receipt, bool unavailable) {
    final order = rows(
      _data['orders'],
    ).where((o) => o['id'] == receipt['purchase_order_id']).firstOrNull;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (widget.openEvidence != null && actor['can_view_prices'] == true)
              Wrap(
                spacing: 8,
                children: [
                  for (final path in {
                    if (receipt['statement_storage_path'] != null)
                      receipt['statement_storage_path'].toString(),
                    for (final line in rows(receipt['lines']))
                      ...((map(line['inspection'])['photo_paths'] as List?) ??
                              [])
                          .map((p) => p.toString()),
                  })
                    TextButton.icon(
                      onPressed: unavailable
                          ? null
                          : () async {
                              try {
                                await widget.openEvidence!(
                                  receipt['id'].toString(),
                                  path,
                                );
                              } catch (e) {
                                if (mounted) {
                                  setState(() => _error = _errorText(e));
                                }
                              }
                            },
                      icon: const Icon(Icons.attachment),
                      label: Text(path.split('/').last),
                    ),
                ],
              ),

            Text(
              '${order?['purchase_order_no'] ?? ''} · ${receipt['inspector_name']} · ${receipt['statement_number'] ?? ''}',
            ),
            for (final line in rows(receipt['lines']))
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${line['product_name']} · ${t('수령 / 합격 / 불합격', 'Received / accepted / rejected', 'Nhận / đạt / loại')}: ${line['received_quantity_base']} / ${line['accepted_quantity_base']} / ${line['rejected_quantity_base']}',
                  ),
                  Text(
                    '${t('유통기한 / 온도', 'Expiry / temperature', 'Hạn dùng / nhiệt độ')}: ${map(line['inspection'])['expiry_date'] ?? '—'} / ${map(line['inspection'])['temperature_c'] ?? '—'} °C · ${line['discrepancy_reason'] ?? ''}',
                  ),
                  if (actor['system'] == 'pos' &&
                      actor['role'] == 'inventory_accounting' &&
                      receipt['status'] == 'confirmed' &&
                      order != null &&
                      enabled)
                    TextButton(
                      onPressed: unavailable
                          ? null
                          : () async {
                              final value = await _fields(
                                t(
                                  '공급업체 반품',
                                  'Return to supplier',
                                  'Trả nhà cung cấp',
                                ),
                                {
                                  'quantity_base': t(
                                    '반품 기준단위 수량',
                                    'Return quantity in base units',
                                    'Số lượng trả đơn vị cơ sở',
                                  ),
                                  'reason': t('반품 사유', 'Reason', 'Lý do'),
                                  'evidence_reference': t(
                                    '실제 반품 증빙',
                                    'Actual return evidence',
                                    'Bằng chứng đã trả hàng',
                                  ),
                                },
                              );
                              if (value != null && mounted) {
                                await _execute('return_goods', order, {
                                  'receipt_line_id': line['id'],
                                  ...value,
                                });
                              }
                            },
                      child: Text(
                        t(
                          '반품 기록·재고 차감',
                          'Record return and reduce stock',
                          'Ghi nhận trả và giảm tồn',
                        ),
                      ),
                    ),
                ],
              ),
          ],
        ),
      ),
    );
  }

  Widget _demandCard(Map<String, dynamic> d) => Card(
    child: ListTile(
      title: Text(
        '${d['product_name']} · ${d['current_stock_base'] ?? '—'} ${d['base_unit']}',
      ),
      subtitle: Text(
        '${t('최소재고 / 일 사용량 / 일 폐기량', 'Minimum / daily usage / daily waste', 'Tối thiểu / dùng mỗi ngày / hủy mỗi ngày')}: ${d['minimum_stock_base'] ?? '—'} / ${d['actual_daily_usage_base']} / ${d['waste_daily_base']}\n${t('입고 예정 / 미발주 요청', 'Inbound / unallocated requests', 'Đang giao / yêu cầu chưa đặt')}: ${d['inbound_quantity_base']} / ${d['pending_request_quantity_base']}\n${d['stock_updated_at'] ?? '—'} · ${d['mapping_count'] == 1 && d['stock_fresh'] == true ? t('재고 자료 확인됨', 'Stock data current', 'Dữ liệu kho hiện hành') : t('재고·품목 연결 확인 필요', 'Stock / item mapping needs review', 'Cần kiểm tra tồn / liên kết mặt hàng')}',
      ),
    ),
  );

  Future<void> _repairLegacyTerms(Map<String, dynamic> order) async {
    final fields = <String, String>{
      'reason': t('보완 사유', 'Review reason', 'Lý do bổ sung'),
      'evidence_reference': t(
        '확정 PO·거래 문서 근거',
        'Confirmed PO / source document reference',
        'Tham chiếu đơn mua / chứng từ đã xác nhận',
      ),
    };
    final initial = <String, String>{};
    final lines = rows(order['lines']);
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i];
      final name = line['product_name'];
      fields['conversion_$i'] =
          '$name · ${t('발주 단위당 기준 수량', 'Base quantity per order unit', 'Lượng cơ sở mỗi đơn vị đặt')}';
      fields['tax_$i'] = '$name · VAT (%)';
      fields['unit_$i'] =
          '$name · ${t('재고 기준 단위 (g/ml/ea)', 'Stock base unit (g/ml/ea)', 'Đơn vị kho cơ sở (g/ml/ea)')}';
      initial['conversion_$i'] =
          line['order_unit_quantity_base_snapshot']?.toString() ?? '';
      initial['tax_$i'] = line['tax_rate_snapshot']?.toString() ?? '';
      initial['unit_$i'] =
          line['base_unit_snapshot']?.toString() ??
          line['current_base_unit'].toString();
    }
    final value = await _fields(
      t(
        '과거 PO 단위·VAT 문서 검토',
        'Review historical PO units and VAT',
        'Kiểm tra đơn vị và VAT đơn cũ',
      ),
      fields,
      initial: initial,
    );
    if (value != null && mounted) {
      await _execute('repair_legacy_terms', order, {
        'reason': value['reason'],
        'evidence_reference': value['evidence_reference'],
        'lines': [
          for (var i = 0; i < lines.length; i++)
            {
              'id': lines[i]['id'],
              'conversion': value['conversion_$i'],
              'tax_rate': value['tax_$i'],
              'base_unit': value['unit_$i'],
            },
        ],
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final requests = rows(_data['requests']);
    final selected = requests.where((r) => r['id'] == _selectedId).firstOrNull;
    final unavailable = _busy || _pending != null;
    return Scaffold(
      appBar: AppBar(
        title: Text(
          t('구매요청·발주', 'Purchase requests & orders', 'Yêu cầu và đơn mua'),
        ),
        actions: [
          IconButton(
            onPressed: _busy ? null : _load,
            icon: const Icon(Icons.refresh),
            tooltip: t('새로고침', 'Refresh', 'Tải lại'),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (_error != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(_error!),
                    ),
                  ),
                if (_pending != null)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            t(
                              '완료 여부를 확인할 요청이 있습니다. 같은 요청으로 재시도할 수 있습니다.',
                              'A saved request needs confirmation. Retry uses the same request identity.',
                              'Có yêu cầu cần xác nhận. Thử lại với cùng mã yêu cầu.',
                            ),
                          ),
                          Wrap(
                            spacing: 12,
                            children: [
                              FilledButton(
                                onPressed: _busy ? null : _retry,
                                child: Text(
                                  t(
                                    '같은 요청 재시도',
                                    'Retry saved request',
                                    'Thử lại',
                                  ),
                                ),
                              ),
                              TextButton(
                                onPressed: _busy ? null : _load,
                                child: Text(
                                  t(
                                    '결과 새로고침·재검토',
                                    'Refresh and review',
                                    'Tải lại và kiểm tra',
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                if (!enabled)
                  Text(
                    t(
                      '이 매장은 아직 새 구매 흐름을 사용하지 않습니다.',
                      'The new purchase flow is not enabled for this store.',
                      'Quy trình mới chưa được bật cho cửa hàng.',
                    ),
                  ),
                Wrap(
                  spacing: 12,
                  runSpacing: 8,
                  children: [
                    if (actor['can_create'] == true)
                      FilledButton.icon(
                        key: const Key('procurement_create_request'),
                        onPressed: enabled && !unavailable
                            ? _editRequest
                            : null,
                        icon: const Icon(Icons.add),
                        label: Text(t('구매요청 작성', 'New request', 'Tạo yêu cầu')),
                      ),
                    if (actor['can_manage'] == true && enabled)
                      TextButton(
                        onPressed: unavailable
                            ? null
                            : () => _execute(
                                'configure',
                                map(_data['policy']),
                                {...map(_data['policy']), 'enabled': false},
                              ),
                        child: Text(
                          t(
                            '새 구매 기능 중지',
                            'Pause new purchasing',
                            'Tạm dừng mua hàng mới',
                          ),
                        ),
                      ),
                    if (actor['can_manage'] == true)
                      OutlinedButton(
                        onPressed: unavailable ? null : _configure,
                        child: Text(
                          t('구매 정책', 'Purchase policy', 'Chính sách mua'),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                ExpansionTile(
                  title: Text(
                    t(
                      '재고·수요 확인',
                      'Stock and demand',
                      'Kiểm tra tồn và nhu cầu',
                    ),
                  ),
                  children: [
                    for (final d in rows(_data['demand'])) _demandCard(d),
                  ],
                ),

                for (final legacy in rows(_data['legacy_terms_review']))
                  Card(
                    child: ListTile(
                      title: Text(
                        '${legacy['purchase_order_no']} · ${t('과거 발주 조건 확인 필요', 'Historical order terms need review', 'Cần kiểm tra điều kiện đơn cũ')}',
                      ),
                      trailing:
                          actor['can_manage'] == true ||
                              actor['can_senior_approve'] == true
                          ? TextButton(
                              onPressed: unavailable
                                  ? null
                                  : () => _repairLegacyTerms(legacy),
                              child: Text(
                                t(
                                  '문서 검토·보완',
                                  'Review source document',
                                  'Kiểm tra chứng từ',
                                ),
                              ),
                            )
                          : null,
                    ),
                  ),
                if (requests.isEmpty)
                  Text(
                    t(
                      '구매요청이 없습니다.',
                      'No purchase requests.',
                      'Chưa có yêu cầu mua hàng.',
                    ),
                  ),
                for (final r in requests)
                  Card(
                    child: ListTile(
                      selected: _selectedId == r['id'],
                      title: Text(
                        '${r['request_no']} · ${label(r['status'].toString())}',
                      ),
                      subtitle: Text(
                        '${r['reason']}\n${r['requested_delivery_date']}',
                      ),
                      isThreeLine: true,
                      onTap: () =>
                          setState(() => _selectedId = r['id'].toString()),
                    ),
                  ),
                if (selected != null) ...[
                  const Divider(),
                  Text(
                    '${selected['request_no']}',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                  for (final line in rows(selected['lines']))
                    ListTile(
                      title: Text(
                        '${line['product_name']} · ${line['requested_quantity']} ${line['requested_unit']}',
                      ),
                      subtitle: Text(
                        '${t('요청 당시 재고', 'Stock at request', 'Tồn kho khi yêu cầu')}: ${line['current_stock_snapshot'] ?? '—'} · ${line['stock_updated_at'] ?? '—'}\n${line['memo'] ?? ''}',
                      ),
                    ),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final action
                          in (selected['allowed_actions'] as List? ?? [])
                              .cast<String>())
                        if ([
                          'save_request',
                          'submit_request',
                          'store_approve',
                          'return_request',
                          'office_approve',
                          'senior_approve',
                        ].contains(action))
                          OutlinedButton(
                            onPressed: unavailable
                                ? null
                                : () => _action(action, selected),
                            child: Text(label(action)),
                          ),
                    ],
                  ),
                ],
                const Divider(),
                Text(
                  t('발주 진행', 'Purchase orders', 'Tiến độ đơn mua'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                for (final order in rows(_data['orders']))
                  Card(
                    child: ListTile(
                      title: Text(
                        '${order['purchase_order_no']} · ${label(order['procurement_status'].toString())}',
                      ),
                      subtitle: Text(
                        '${order['supplier_name']} · ${order['requested_delivery_date']}',
                      ),
                      trailing: widget.onOpenOrder == null
                          ? null
                          : IconButton(
                              onPressed: () =>
                                  widget.onOpenOrder!(order['id'].toString()),
                              icon: const Icon(Icons.inventory_2_outlined),
                            ),
                    ),
                  ),
                for (final receipt in rows(_data['receipts']))
                  _receiptCard(receipt, unavailable),
                const Divider(),
                Text(
                  t('처리 이력', 'History', 'Lịch sử'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                for (final e in rows(_data['events']).where(
                  (e) => _selectedId == null || e['record_id'] == _selectedId,
                ))
                  ListTile(
                    dense: true,
                    title: Text(label(e['action'].toString())),
                    subtitle: Text(
                      '${e['created_at']} · ${map(e['actor'])['system']} · ${map(e['actor'])['subject_id']}\n${e['reason'] ?? ''}',
                    ),
                  ),
              ],
            ),
    );
  }
}

class ProcurementRequestDialog extends StatefulWidget {
  const ProcurementRequestDialog({
    super.key,
    required this.products,
    required this.supplierItems,
    this.initial,
  });
  final List<Map<String, dynamic>> products, supplierItems;
  final Map<String, dynamic>? initial;
  @override
  State<ProcurementRequestDialog> createState() =>
      _ProcurementRequestDialogState();
}

class _ProcurementRequestDialogState extends State<ProcurementRequestDialog> {
  final _form = GlobalKey<FormState>();
  late TextEditingController _reason, _date, _memo;
  late List<Map<String, dynamic>> _lines;
  String t(String ko, String en, String vi) =>
      switch (Localizations.localeOf(context).languageCode) {
        'ko' => ko,
        'vi' => vi,
        _ => en,
      };
  @override
  void initState() {
    super.initState();
    final r = widget.initial;
    _reason = TextEditingController(text: r?['reason']?.toString());
    _date = TextEditingController(
      text:
          r?['requested_delivery_date']?.toString() ??
          DateTime.now().toIso8601String().substring(0, 10),
    );
    _memo = TextEditingController(text: r?['memo']?.toString());
    _lines = (r?['lines'] as List? ?? [])
        .map(
          (e) => Map<String, dynamic>.from(e as Map)
            ..['quantity'] = e['requested_quantity']?.toString()
            ..['unit'] = e['requested_unit']
            ..['_key'] = const Uuid().v4(),
        )
        .toList();
    if (_lines.isEmpty) {
      _lines.add({'_key': const Uuid().v4(), 'quantity': '1'});
    }
  }

  @override
  void dispose() {
    _reason.dispose();
    _date.dispose();
    _memo.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('구매요청', 'Purchase request', 'Yêu cầu mua hàng')),
    content: SizedBox(
      width: 700,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _reason,
                decoration: InputDecoration(
                  labelText: t('구매 사유 *', 'Reason *', 'Lý do *'),
                ),
                validator: (s) => s == null || s.trim().isEmpty
                    ? t('필수 입력', 'Required', 'Bắt buộc')
                    : null,
              ),
              TextFormField(
                controller: _date,
                decoration: InputDecoration(
                  labelText: t(
                    '희망 입고일 (YYYY-MM-DD)',
                    'Required date (YYYY-MM-DD)',
                    'Ngày cần hàng (YYYY-MM-DD)',
                  ),
                ),
                validator: (s) =>
                    s != null &&
                        RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(s) &&
                        DateTime.tryParse(
                              s,
                            )?.toIso8601String().substring(0, 10) ==
                            s
                    ? null
                    : t('날짜 확인', 'Check the date', 'Kiểm tra ngày'),
              ),
              TextFormField(
                controller: _memo,
                decoration: InputDecoration(
                  labelText: t('비고', 'Notes', 'Ghi chú'),
                ),
              ),
              for (final line in _lines)
                Padding(
                  key: ValueKey(line['_key']),
                  padding: const EdgeInsets.only(top: 16),
                  child: Column(
                    children: [
                      DropdownButtonFormField<String>(
                        initialValue: line['product_id'] as String?,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: t('품목', 'Item', 'Mặt hàng'),
                        ),
                        items: widget.products
                            .map(
                              (p) => DropdownMenuItem(
                                value: p['id'].toString(),
                                child: Text(
                                  '${p['name']} · ${t('현재고', 'Stock', 'Tồn')}: ${p['current_stock'] ?? '—'} ${p['base_unit']}',
                                ),
                              ),
                            )
                            .toList(),
                        validator: (s) => s == null
                            ? t('품목 선택', 'Choose item', 'Chọn mặt hàng')
                            : null,
                        onChanged: (id) => setState(() {
                          line['product_id'] = id;
                          line['unit'] = widget.products.firstWhere(
                            (p) => p['id'] == id,
                          )['stock_unit'];
                          line['preferred_supplier_id'] = null;
                        }),
                      ),
                      Row(
                        children: [
                          Expanded(
                            child: TextFormField(
                              initialValue: line['quantity']?.toString(),
                              keyboardType:
                                  const TextInputType.numberWithOptions(
                                    decimal: true,
                                  ),
                              decoration: InputDecoration(
                                labelText: t('필요 수량', 'Quantity', 'Số lượng'),
                              ),
                              onChanged: (s) => line['quantity'] = s,
                              validator: (s) =>
                                  s != null &&
                                      RegExp(
                                        r'^\d+(\.\d{1,3})?$',
                                      ).hasMatch(s) &&
                                      (double.tryParse(s) ?? 0) > 0 &&
                                      (double.tryParse(s)?.isFinite ?? false)
                                  ? null
                                  : t(
                                      '양수·소수 3자리 이내',
                                      'Positive, up to 3 decimals',
                                      'Số dương, tối đa 3 số lẻ',
                                    ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: DropdownButtonFormField<String>(
                              key: ValueKey(
                                '${line['_key']}:${line['product_id']}',
                              ),
                              initialValue: line['unit'] as String?,
                              decoration: InputDecoration(
                                labelText: t('단위', 'Unit', 'Đơn vị'),
                              ),
                              items: widget.products
                                  .where((p) => p['id'] == line['product_id'])
                                  .expand(
                                    (p) => <String>{
                                      p['stock_unit'].toString(),
                                      p['base_unit'].toString(),
                                    },
                                  )
                                  .map(
                                    (u) => DropdownMenuItem(
                                      value: u,
                                      child: Text(u),
                                    ),
                                  )
                                  .toList(),
                              onChanged: (u) => line['unit'] = u,
                              validator: (s) => s == null
                                  ? t('단위 선택', 'Select unit', 'Chọn đơn vị')
                                  : null,
                            ),
                          ),
                          IconButton(
                            onPressed: _lines.length > 1
                                ? () => setState(() => _lines.remove(line))
                                : null,
                            icon: const Icon(Icons.delete_outline),
                            tooltip: t('품목 삭제', 'Remove item', 'Xóa mặt hàng'),
                          ),
                        ],
                      ),
                      DropdownButtonFormField<String>(
                        key: ValueKey(
                          'supplier:${line['_key']}:${line['product_id']}',
                        ),
                        initialValue: line['preferred_supplier_id'] as String?,
                        isExpanded: true,
                        decoration: InputDecoration(
                          labelText: t(
                            '권장 공급업체 (선택)',
                            'Suggested supplier (optional)',
                            'Nhà cung cấp đề xuất (tùy chọn)',
                          ),
                        ),
                        items:
                            {
                                  for (final s in widget.supplierItems.where(
                                    (s) =>
                                        s['product_id'] == line['product_id'],
                                  ))
                                    s['supplier_id'].toString():
                                        s['supplier_name'].toString(),
                                }.entries
                                .map(
                                  (e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Text(e.value),
                                  ),
                                )
                                .toList(),
                        onChanged: (s) => line['preferred_supplier_id'] = s,
                      ),
                      TextFormField(
                        initialValue: line['memo']?.toString(),
                        decoration: InputDecoration(
                          labelText: t(
                            '품목 비고',
                            'Item note',
                            'Ghi chú mặt hàng',
                          ),
                        ),
                        onChanged: (s) => line['memo'] = s,
                      ),
                    ],
                  ),
                ),
              TextButton.icon(
                onPressed: () => setState(
                  () =>
                      _lines.add({'_key': const Uuid().v4(), 'quantity': '1'}),
                ),
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
        onPressed: () => Navigator.pop(context),
        child: Text(t('취소', 'Cancel', 'Hủy')),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, {
              'reason': _reason.text.trim(),
              'requested_delivery_date': _date.text,
              'memo': _memo.text,
              'lines': _lines
                  .map((l) => Map<String, dynamic>.from(l)..remove('_key'))
                  .toList(),
            });
          }
        },
        child: Text(t('저장', 'Save', 'Lưu')),
      ),
    ],
  );
}

class ProcurementFieldsDialog extends StatefulWidget {
  const ProcurementFieldsDialog({
    super.key,
    required this.title,
    required this.fields,
    this.initial = const {},
  });
  final String title;
  final Map<String, String> fields, initial;
  @override
  State<ProcurementFieldsDialog> createState() =>
      _ProcurementFieldsDialogState();
}

class _ProcurementFieldsDialogState extends State<ProcurementFieldsDialog> {
  final _form = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers;
  @override
  void initState() {
    super.initState();
    _controllers = {
      for (final k in widget.fields.keys)
        k: TextEditingController(text: widget.initial[k]),
    };
  }

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.title),
    content: SizedBox(
      width: 560,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final e in widget.fields.entries)
                TextFormField(
                  controller: _controllers[e.key],
                  decoration: InputDecoration(labelText: e.value),
                  validator: (s) => s == null || s.trim().isEmpty ? '*' : null,
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
      ),
      FilledButton(
        onPressed: () {
          if (_form.currentState!.validate()) {
            Navigator.pop(context, {
              for (final e in _controllers.entries) e.key: e.value.text.trim(),
            });
          }
        },
        child: Text(MaterialLocalizations.of(context).okButtonLabel),
      ),
    ],
  );
}
