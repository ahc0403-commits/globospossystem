import 'procurement_metrics.dart';
import 'procurement_catalog_dialog.dart';
import 'procurement_process_labels.dart';
import 'dart:convert';
import '../../core/utils/time_utils.dart';
import 'procurement_presentation.dart';
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

typedef ProcurementPageLoad =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> query);
typedef ProcurementExport =
    Future<void> Function(
      String kind,
      Map<String, dynamic> record,
      String audience,
    );

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
    this.loadPage,
    this.exportDocument,
    this.openEvidence,
    this.requesterView = false,
    this.onOpenReceiving,
    this.onOpenLegacy,
    this.onLogout,
    this.refreshListenable,
  });
  final Future<void> Function(String receiptId, String path)? openEvidence;
  final Listenable? refreshListenable;
  final bool requesterView;
  final VoidCallback? onOpenReceiving, onOpenLegacy, onLogout;
  final ProcurementLoad load;
  final ProcurementPageLoad? loadPage;
  final ProcurementExport? exportDocument;
  final ProcurementExecute execute;
  final ValueChanged<String>? onOpenOrder;
  @override
  State<ProcurementWorkspacePage> createState() =>
      _ProcurementWorkspacePageState();
}

class _ProcurementWorkspacePageState extends State<ProcurementWorkspacePage> {
  Map<String, dynamic> _data = {};
  final Map<String, dynamic> _query = {};
  String? _selectedOrderId;
  String copy(String key) => procurementProcessLabel(
    key,
    Localizations.localeOf(context).languageCode,
  );

  Map<String, dynamic>? _pending;
  String? _selectedId, _error, _journalKey;
  bool _loading = true, _busy = false, _needsListRefresh = false;
  int _generation = 0;
  String _period = 'recent';
  String? _notice;
  final _search = TextEditingController();
  final _scroll = ScrollController();
  bool get requesterView =>
      widget.requesterView ||
      (actor['can_create'] == true &&
          actor['can_view_prices'] != true &&
          actor['can_manage'] != true &&
          actor['can_office_approve'] != true);
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
    _query.addAll(procurementRecentMonth());
    _query['request_group'] = 'pending';
    _query['request_sort'] = 'created';
    if (widget.requesterView) _query['request_view'] = true;
    widget.refreshListenable?.addListener(_refresh);
    _load();
  }

  void _refresh() {
    if (!_busy && _pending == null) _load();
  }

  @override
  void dispose() {
    widget.refreshListenable?.removeListener(_refresh);
    _search.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<bool> _load() async {
    final generation = ++_generation;
    if (mounted) setState(() => _loading = true);
    try {
      final data = widget.loadPage == null
          ? await widget.load()
          : await widget.loadPage!({
              ..._query,
              if (_selectedId != null) 'request_id': _selectedId,
              if (_selectedOrderId != null) 'order_id': _selectedOrderId,
            });
      if (data['contract_version'] != 2) {
        throw StateError('PROCUREMENT_CONTRACT_NOT_READY');
      }
      if (widget.loadPage != null) {
        final incoming = rows(data['products']);
        if (_selectedId == null && _selectedOrderId == null) {
          // Catalog pagination is owned by the request editor.
        } else {
          data['products'] = {
            for (final p in [...rows(_data['products']), ...incoming])
              p['id']: p,
          }.values.toList();
          data['supplier_items'] = {
            for (final p in [
              ...rows(_data['supplier_items']),
              ...rows(data['supplier_items']),
            ])
              p['id']: p,
          }.values.toList();
          data['catalog_has_more'] =
              _data['catalog_has_more'] ?? data['catalog_has_more'];
        }
      }
      final identity = map(data['actor']);
      final key =
          'procurement.command.${identity['system']}.${identity['subject_id']}.${data['store_id']}';
      final raw = (await SharedPreferences.getInstance()).getString(key);
      final pending = raw == null ? null : map(jsonDecode(raw));
      if (!mounted || generation != _generation) return false;
      setState(() {
        _data = data;
        _journalKey = key;
        _pending = pending;
        _loading = false;
        _needsListRefresh = false;
        _error = null;
      });
      return true;
    } catch (e) {
      if (mounted && generation == _generation) {
        setState(() {
          _loading = false;
          _error = _errorText(e);
        });
      }
      return false;
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

  Future<bool> _execute(
    String action,
    Map<String, dynamic>? record,
    Map<String, dynamic> payload,
  ) async {
    if (_busy || _pending != null || _journalKey == null) return false;
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
      if (!mounted) return false;
      setState(() => _pending = pending);
      await _sendPending();
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
      return false;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sendPending() async {
    final p = _pending;
    if (p == null) return;
    late Map<String, dynamic> result;
    try {
      result = await widget.execute(
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
    final action = p['action'];
    setState(() {
      _pending = null;
      if ([
        'create_request',
        'save_request',
        'submit_request',
        'cancel_request',
      ].contains(action)) {
        _resetPages();
        _selectedOrderId = null;
        _selectedId = action == 'cancel_request'
            ? null
            : result['id']?.toString();
        if (action == 'create_request') {
          _query.remove('search');
          _query.remove('purchase_category');
          _search.clear();
          _query.addAll(procurementRecentMonth());
          _period = 'recent';
          _query['request_group'] = 'pending';
        }
        if (action == 'cancel_request') _data.remove('request_detail');
        _notice =
            '${result['request_no'] ?? ''} · ${copy(action == 'cancel_request' ? 'deleted' : 'saved')} · ${label(result['status']?.toString() ?? 'draft')}';
      }
    });
    if (!await _load() && mounted) {
      setState(() => _needsListRefresh = true);
    }
    if (action == 'create_request' && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _scroll.hasClients) _scroll.jumpTo(0);
      });
    }
  }

  void _resetPages() {
    _query.removeWhere(
      (key, _) => key.contains('_before') || key == 'catalog_after',
    );
  }

  void _filter(String key, String? value) {
    setState(() {
      if (value == null || value.isEmpty) {
        _query.remove(key);
      } else {
        _query[key] = value;
      }
      _resetPages();
      _selectedId = null;
      _selectedOrderId = null;
    });
    _load();
  }

  Future<void> _choosePeriod(String? value) async {
    if (value == 'recent') {
      setState(() {
        _period = 'recent';
        _query.addAll(procurementRecentMonth());
        _resetPages();
        _selectedId = null;
        _selectedOrderId = null;
      });
      await _load();
      return;
    }
    final now = TimeUtils.nowVietnam();
    final selected = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2000),
      lastDate: DateTime(now.year + 5, 12, 31),
      initialDateRange: DateTimeRange(
        start: DateTime.parse(_query['created_from'].toString()),
        end: DateTime.parse(_query['created_to'].toString()),
      ),
    );
    if (selected == null || !mounted) return;
    setState(() {
      _period = 'custom';
      _query['created_from'] = procurementDate(
        selected.start.toIso8601String().substring(0, 10),
      );
      _query['created_to'] = procurementDate(
        selected.end.toIso8601String().substring(0, 10),
      );
      _resetPages();
      _selectedId = null;
      _selectedOrderId = null;
    });
    await _load();
  }

  Future<bool> _retry() async {
    if (_busy || _pending == null) return false;
    setState(() => _busy = true);
    try {
      await _sendPending();
      return true;
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
      return false;
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
    'brand_review' => copy('brand_review'),
    'brand_approve' => copy('brand_approve'),
    'adjust_request' => copy('adjust_request'),
    'cancel_request' => copy('cancel_request'),
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
    'submit_request' => t('승인 요청', 'Submit for approval', 'Gửi duyệt'),
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
    await showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (c) => ProcurementRequestDialog(
        products: rows(_data['products']),
        supplierItems: rows(_data['supplier_items']),
        initial: request,
        catalogHasMore: _data['catalog_has_more'] == true,
        loadCatalog: widget.loadPage == null
            ? null
            : (query) => widget.loadPage!({
                ...query,
                if (request != null) 'request_id': request['id'],
              }),
        saveRequest: (payload) async =>
            await _execute(
              request == null ? 'create_request' : 'save_request',
              request,
              payload,
            )
            ? null
            : (_error ?? copy('saveFailed')),
        needsConfirmation: () => _pending != null,
        retrySavedRequest: () async =>
            await _retry() ? null : (_error ?? copy('saveFailed')),
      ),
    );
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

  Future<void> _saveProduct() async {
    final value = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => ProcurementCatalogDialog(
        label: copy,
        suppliers: {
          for (final s in rows(_data['supplier_items']))
            s['supplier_id'].toString(): s['supplier_name'].toString(),
        },
      ),
    );
    if (value != null) await _execute('save_product', null, value);
  }

  Widget _accountingStatus(Map<String, dynamic> order) {
    final status = map(order['accounting_status']);
    if (status.isEmpty) return const SizedBox.shrink();
    return Text(
      '${copy('accountingStatus')}: ${status['invoice_count']} / ${status['payable_count']} / ${status['held_count']} / ${status['paid_count']}\n${status['stale'] == true || status['reconciliation_required'] == true ? copy('accountingRefresh') : status['observed_at'] ?? ''}',
    );
  }

  Future<void> _toggleNewRequests() async {
    final policy = map(_data['policy']);
    await _execute(
      'configure',
      {...policy, 'id': _data['store_id']},
      {
        ...policy,
        'enabled': true,
        'new_requests_enabled': policy['new_requests_enabled'] == false,
      },
    );
  }

  Future<void> _nextEvidence(String kind) async {
    final key = switch (kind) {
      'receipt' => 'receipts',
      'event' => 'events',
      'issue' => 'issues',
      'return' => 'returns',
      'legacy' => 'legacy_terms_review',
      _ => 'quotes',
    };
    final list = kind == 'quote'
        ? rows(map(_data['request_detail'])['quotes'])
        : rows(_data[key]);
    if (list.isEmpty) return;
    final last = list.last;
    _query['${kind}_before'] =
        last[kind == 'receipt' ? 'received_at' : 'created_at'];
    _query['${kind}_before_id'] = last['id'];
    await _load();
  }

  Future<void> _selectRequest(String id) async {
    _query.removeWhere(
      (key, _) => [
        'receipt_',
        'event_',
        'issue_',
        'return_',
        'quote_',
      ].any(key.startsWith),
    );
    setState(() {
      _selectedId = id;
      _selectedOrderId = null;
    });
    if (widget.loadPage != null) await _load();
  }

  Future<void> _selectOrder(String id) async {
    _query.removeWhere(
      (key, _) =>
          ['receipt_', 'event_', 'issue_', 'return_'].any(key.startsWith),
    );
    setState(() {
      _selectedOrderId = id;
    });
    if (widget.loadPage != null) await _load();
  }

  Future<void> _next(String kind) async {
    final records = rows(_data[kind == 'request' ? 'requests' : 'orders']);
    if (records.isEmpty) return;
    final last = records.last;
    _query['${kind}_before'] = last['created_at'];
    _query['${kind}_before_id'] = last['id'];
    _selectedId = null;
    _selectedOrderId = null;
    await _load();
  }

  Future<void> _export(
    String kind,
    Map<String, dynamic> record,
    String audience,
  ) async {
    if (widget.exportDocument == null) return;
    setState(() => _busy = true);
    try {
      await widget.exportDocument!(kind, record, audience);
      await _load();
    } catch (e) {
      if (mounted) setState(() => _error = _errorText(e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _dates(Map<String, dynamic> r) {
    final terms = map(r['commercial_terms']);
    return copy('dates')
        .replaceAll(
          '{0}',
          procurementDate(
            r['pr_created_at'] ?? terms['pr_created_at'] ?? r['created_at'],
          ),
        )
        .replaceAll(
          '{1}',
          procurementDate(
            r['pr_submitted_at'] ??
                terms['pr_submitted_at'] ??
                r['submitted_at'],
            includeTime: true,
          ),
        )
        .replaceAll(
          '{2}',
          procurementDate(
            r['issued_at'] ?? terms['issued_at'],
            includeTime: true,
          ),
        );
  }

  Future<void> _action(String action, Map<String, dynamic> request) async {
    if (action == 'save_request') {
      await _editRequest(request);
      return;
    }
    if (action == 'adjust_request') {
      final lines = rows(request['lines']);
      final value = await _fields(
        copy('adjust_request'),
        {
          'reason': copy('reason'),
          for (final l in lines)
            l['id'].toString(): '${l['product_name']} · ${l['requested_unit']}',
        },
        initial: {
          for (final l in lines)
            l['id'].toString(): l['requested_quantity'].toString(),
        },
      );
      if (value != null) {
        await _execute(action, request, {
          'reason': value['reason'],
          'lines': [
            for (final l in lines)
              {
                'request_line_id': l['id'],
                'quantity': value[l['id'].toString()],
              },
          ],
        });
      }
      return;
    }
    if (action == 'cancel_request' &&
        requesterView &&
        ['draft', 'returned'].contains(request['status'])) {
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (c) => AlertDialog(
          title: Text(copy('deleteDraft')),
          content: Text(copy('deleteDraftMessage')),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(c, false),
              child: Text(t('취소', 'Cancel', 'Hủy')),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(c, true),
              child: Text(copy('deleteDraft')),
            ),
          ],
        ),
      );
      if (confirmed == true) {
        await _execute(action, request, {'reason': 'deleted_before_submit'});
      }
      return;
    }
    if (action == 'return_request' || action == 'cancel_request') {
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
    if (!mounted) return;
    final activate = await showDialog<bool>(
      context: context,
      builder: (c) => AlertDialog(
        title: Text(copy('activatePolicy')),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(c, false),
            child: const Icon(Icons.close),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(c, true),
            child: const Icon(Icons.check),
          ),
        ],
      ),
    );
    if (activate != true || !mounted) return;
    await _execute('configure', policy.isEmpty ? null : policy, {
      'enabled': true,
      'three_stage_required': true,
      'quantity_review_multiplier': quantityMultiplier,
      'high_value_amount': amount,
      'max_price_increase_percent': percent,
      'stock_freshness_hours': policy['stock_freshness_hours'] ?? 24,
    });
  }

  Widget _receiptCard(Map<String, dynamic> receipt, bool unavailable) {
    final detail = map(_data['order_detail']);
    final order = detail['id'] == receipt['purchase_order_id']
        ? detail
        : rows(
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
    final detail = map(_data['request_detail']);
    final selected = detail['id'] == _selectedId && detail.isNotEmpty
        ? detail
        : requests.where((r) => r['id'] == _selectedId).firstOrNull;
    final unavailable = _busy || _pending != null;
    final compact = MediaQuery.sizeOf(context).width < 600;
    return Scaffold(
      appBar: AppBar(
        title: Text(copy(widget.requesterView ? 'management' : 'historyTitle')),
        actions: [
          if (compact &&
              (widget.onOpenReceiving != null || widget.onOpenLegacy != null))
            PopupMenuButton<String>(
              enabled: !unavailable,
              onSelected: (value) => value == 'receiving'
                  ? widget.onOpenReceiving?.call()
                  : widget.onOpenLegacy?.call(),
              itemBuilder: (_) => [
                if (widget.onOpenReceiving != null)
                  PopupMenuItem(
                    value: 'receiving',
                    child: Text(copy('receiving')),
                  ),
                if (widget.onOpenLegacy != null)
                  PopupMenuItem(
                    value: 'legacy',
                    child: Text(copy('legacyOrders')),
                  ),
              ],
            ),
          if (!compact && widget.onOpenReceiving != null)
            TextButton(
              onPressed: unavailable ? null : widget.onOpenReceiving,
              child: Text(copy('receiving')),
            ),
          if (!compact && widget.onOpenLegacy != null)
            TextButton(
              onPressed: unavailable ? null : widget.onOpenLegacy,
              child: Text(copy('legacyOrders')),
            ),
          if (widget.onLogout != null)
            IconButton(
              onPressed: unavailable ? null : widget.onLogout,
              icon: const Icon(Icons.logout),
              tooltip: copy('logout'),
            ),
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
              controller: _scroll,
              padding: const EdgeInsets.all(20),
              children: [
                if (widget.requesterView)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: Text(copy('requestApprovals')),
                  ),
                if (_notice != null || _needsListRefresh)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(
                      _needsListRefresh ? copy('savedRefreshNeeded') : _notice!,
                      key: const Key('procurement_command_notice'),
                    ),
                  ),
                if (widget.requesterView)
                  Text(
                    copy('historyTitle'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
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
                    if (widget.loadPage != null)
                      SizedBox(
                        width: 190,
                        child: DropdownButtonFormField<String>(
                          isExpanded: true,
                          key: ValueKey(
                            'procurement_category:${_query['purchase_category']}',
                          ),
                          initialValue:
                              _query['purchase_category']?.toString() ?? '',
                          decoration: InputDecoration(
                            labelText: copy('category'),
                          ),
                          items: [
                            for (final category in [
                              '',
                              'raw_material',
                              'tools',
                              'beverage',
                              'other',
                            ])
                              DropdownMenuItem(
                                value: category,
                                child: Text(
                                  copy(category.isEmpty ? 'all' : category),
                                ),
                              ),
                          ],
                          onChanged: unavailable
                              ? null
                              : (value) => _filter('purchase_category', value),
                        ),
                      ),
                    if (widget.loadPage != null)
                      SizedBox(
                        width: 240,
                        child: TextField(
                          controller: _search,
                          decoration: InputDecoration(
                            labelText: copy('searchRecords'),
                          ),
                          onSubmitted: unavailable
                              ? null
                              : (value) => _filter('search', value.trim()),
                        ),
                      ),
                    if (widget.loadPage != null)
                      SizedBox(
                        width: 190,
                        child: DropdownButtonFormField<String>(
                          isExpanded: true,
                          key: ValueKey(
                            'procurement_period:$_period:${_query['created_from']}:${_query['created_to']}',
                          ),
                          initialValue: _period,
                          decoration: InputDecoration(
                            labelText: copy('period'),
                          ),
                          items: [
                            DropdownMenuItem(
                              value: 'recent',
                              child: Text(copy('recentMonth')),
                            ),
                            DropdownMenuItem(
                              value: 'custom',
                              child: Text(copy('customPeriod')),
                            ),
                          ],
                          onChanged: unavailable ? null : _choosePeriod,
                        ),
                      ),
                    if (!requesterView && actor['can_office_approve'] == true)
                      TextButton(
                        onPressed: unavailable || !enabled
                            ? null
                            : _saveProduct,
                        child: Text(copy('catalogSetup')),
                      ),
                    if (actor['can_create'] == true)
                      FilledButton.icon(
                        key: const Key('procurement_create_request'),
                        onPressed:
                            enabled &&
                                !unavailable &&
                                map(_data['policy'])['new_requests_enabled'] !=
                                    false
                            ? _editRequest
                            : null,
                        icon: const Icon(Icons.add),
                        label: Text(t('구매요청 작성', 'New request', 'Tạo yêu cầu')),
                      ),
                    if (actor['can_manage'] == true && enabled)
                      TextButton(
                        onPressed: unavailable ? null : _toggleNewRequests,
                        child: Text(
                          copy(
                            map(_data['policy'])['new_requests_enabled'] ==
                                    false
                                ? 'resumeNew'
                                : 'pauseNew',
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
                if (!requesterView)
                  ExpansionTile(
                    title: Text(copy('operatingMetrics')),
                    onExpansionChanged: (v) {
                      if (v && _query['include_metrics'] != true) {
                        _query['include_metrics'] = true;
                        _load();
                      }
                    },
                    children: [
                      ProcurementMetrics(
                        data: map(_data['operating_metrics']),
                        label: copy,
                      ),
                    ],
                  ),
                if (!requesterView)
                  ExpansionTile(
                    initiallyExpanded: _query['include_evidence'] == true,
                    onExpansionChanged: (v) {
                      if (v && _query['include_evidence'] != true) {
                        _query['include_evidence'] = true;
                        _load();
                      }
                    },
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

                if (widget.loadPage != null && actor['can_view_prices'] == true)
                  TextButton(
                    onPressed: unavailable
                        ? null
                        : () {
                            _query['include_legacy'] = true;
                            _load();
                          },
                    child: Text(copy('legacyReview')),
                  ),
                if (_data['legacy_has_more'] == true)
                  TextButton(
                    onPressed: unavailable
                        ? null
                        : () => _nextEvidence('legacy'),
                    child: Text(copy('nextLegacy')),
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
                Text(
                  copy('requestOverview'),
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                if (widget.loadPage != null)
                  Wrap(
                    spacing: 8,
                    children: [
                      for (final group in ['pending', 'approved', 'cancelled'])
                        ChoiceChip(
                          label: Text(
                            '${copy('group_$group')} (${map(_data['request_counts'])[group] ?? 0})',
                          ),
                          selected: _query['request_group'] == group,
                          onSelected: unavailable
                              ? null
                              : (_) => _filter('request_group', group),
                        ),
                    ],
                  ),
                if (widget.loadPage != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Text(
                      '${copy('period')}: ${_query['created_from']} ~ ${_query['created_to']}',
                    ),
                  ),
                Text(
                  copy('requestList'),
                  style: Theme.of(context).textTheme.titleMedium,
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
                        '${copy('requestDate')} ${procurementDate(r['created_at'])} / ${copy('requiredDate')} ${procurementDate(r['requested_delivery_date'])}\n${r['reason']} · ${copy(r['purchase_category']?.toString() ?? 'raw_material')} · ${r['line_count'] ?? rows(r['lines']).length} ${copy('itemCount')}',
                      ),
                      isThreeLine: true,
                      onTap: () => _selectRequest(r['id'].toString()),
                    ),
                  ),
                if (_data['request_has_more'] == true)
                  TextButton(
                    onPressed: unavailable ? null : () => _next('request'),
                    child: Text(copy('nextRequests')),
                  ),
                if (selected != null) ...[
                  Text(
                    '${copy('requestDate')} ${procurementDate(selected['created_at'])} / ${copy('requiredDate')} ${procurementDate(selected['requested_delivery_date'])}',
                  ),
                  if (widget.exportDocument != null)
                    TextButton(
                      onPressed: unavailable
                          ? null
                          : () => _export('pr', selected, 'internal'),
                      child: Text(copy('prPdf')),
                    ),
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
                        '${t('요청 당시 재고', 'Stock at request', 'Tồn kho khi yêu cầu')}: ${procurementNumber(line['current_stock_snapshot'], decimals: 3)}\n${line['memo'] ?? ''}\n${copy('estimate')}: ${line['estimated_unit_price'] == null ? copy('quoteNeeded') : procurementNumber(line['estimated_unit_price'])} / ${line['estimated_order_unit'] ?? '—'}',
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
                              'adjust_request',
                              'brand_approve',
                              'cancel_request',
                              'return_request',
                              'office_approve',
                              'senior_approve',
                            ].contains(action) &&
                            (![
                                  'save_request',
                                  'submit_request',
                                ].contains(action) ||
                                [
                                  'draft',
                                  'returned',
                                ].contains(selected['status'])))
                          OutlinedButton(
                            onPressed: unavailable
                                ? null
                                : () => _action(action, selected),
                            child: Text(
                              action == 'cancel_request' &&
                                      requesterView &&
                                      [
                                        'draft',
                                        'returned',
                                      ].contains(selected['status'])
                                  ? copy('deleteDraft')
                                  : label(action),
                            ),
                          ),
                    ],
                  ),
                ],
                const Divider(),
                if (!requesterView || _selectedId != null)
                  Text(
                    t('발주 진행', 'Purchase orders', 'Tiến độ đơn mua'),
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                for (final order in rows(_data['orders']))
                  Card(
                    child: ListTile(
                      onTap: () => _selectOrder(order['id'].toString()),
                      title: Text(
                        '${order['purchase_order_no']} · ${label(order['procurement_status'].toString())}',
                      ),
                      subtitle: Text(
                        '${order['supplier_name']} · ${order['requested_delivery_date']}\n${_dates(order)}',
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
                if (map(_data['order_detail']).isNotEmpty)
                  _accountingStatus(map(_data['order_detail'])),
                if (_data['order_has_more'] == true)
                  TextButton(
                    onPressed: unavailable ? null : () => _next('order'),
                    child: Text(copy('nextOrders')),
                  ),
                if (_data['receipt_has_more'] == true)
                  TextButton(
                    onPressed: unavailable
                        ? null
                        : () => _nextEvidence('receipt'),
                    child: Text(copy('nextReceipts')),
                  ),
                for (final returned in rows(_data['returns']))
                  ListTile(
                    title: Text(
                      '${label('return_goods')} · ${returned['quantity_base']}',
                    ),
                    subtitle: Text(
                      '${returned['created_at']} · ${returned['reason']} · ${returned['evidence_reference']}',
                    ),
                  ),
                for (final receipt in rows(_data['receipts']))
                  _receiptCard(receipt, unavailable),
                const Divider(),
                if (_data['event_has_more'] == true)
                  TextButton(
                    onPressed: unavailable
                        ? null
                        : () => _nextEvidence('event'),
                    child: Text(copy('nextEvents')),
                  ),
                Text(
                  t('처리 이력', 'History', 'Lịch sử'),
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                for (final kind in ['issue', 'return', 'quote'])
                  if (_data['${kind}_has_more'] == true)
                    TextButton(
                      onPressed: unavailable ? null : () => _nextEvidence(kind),
                      child: Text(
                        copy(
                          'next${kind[0].toUpperCase()}${kind.substring(1)}s',
                        ),
                      ),
                    ),
                for (final e in rows(_data['events']).where(
                  (e) =>
                      _selectedId == null ||
                      e['record_id'] == _selectedId ||
                      e['record_id'] == _selectedOrderId,
                ))
                  ListTile(
                    dense: true,
                    title: Text(label(e['action'].toString())),
                    subtitle: Text(
                      '${procurementDate(e['created_at'], includeTime: true)} · ${map(e['actor'])['display_name'] ?? map(e['actor'])['role'] ?? map(e['actor'])['system']}\n${e['reason'] ?? ''}',
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
    this.loadCatalog,
    this.catalogHasMore = false,
    this.saveRequest,
    this.needsConfirmation,
    this.retrySavedRequest,
  });
  final ProcurementPageLoad? loadCatalog;
  final bool catalogHasMore;
  final Future<String?> Function(Map<String, dynamic>)? saveRequest;
  final bool Function()? needsConfirmation;
  final Future<String?> Function()? retrySavedRequest;
  final List<Map<String, dynamic>> products, supplierItems;
  final Map<String, dynamic>? initial;
  @override
  State<ProcurementRequestDialog> createState() =>
      _ProcurementRequestDialogState();
}

class _ProcurementRequestDialogState extends State<ProcurementRequestDialog> {
  String copy(String key) => procurementProcessLabel(
    key,
    Localizations.localeOf(context).languageCode,
  );

  String _category = 'raw_material', _channel = 'ordinary';
  late List<Map<String, dynamic>> _products, _supplierItems;
  bool _catalogLoading = false, _saving = false, _catalogHasMore = false;
  bool _needsConfirmation = false;
  String? _catalogAfter, _saveError;
  String _catalogSearch = '';
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
    _products = [...widget.products];
    _supplierItems = [...widget.supplierItems];
    _catalogHasMore = widget.catalogHasMore;
    _catalogAfter = _products.lastOrNull?['id']?.toString();
    _category = r?['purchase_category']?.toString() ?? 'raw_material';
    _channel = r?['purchase_channel']?.toString() ?? 'ordinary';
    _reason = TextEditingController(text: r?['reason']?.toString());
    _date = TextEditingController(
      text:
          r?['requested_delivery_date']?.toString() ??
          procurementDate(
            TimeUtils.nowVietnam().toIso8601String().substring(0, 10),
          ),
    );
    _memo = TextEditingController(text: r?['memo']?.toString());
    _lines = (r?['lines'] as List? ?? [])
        .map(
          (e) => Map<String, dynamic>.from(e as Map)
            ..['quantity'] = (e['requested_quantity'] ?? e['quantity'])
                ?.toString()
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

  Future<void> _loadCatalog({bool more = false}) async {
    if (_catalogLoading || widget.loadCatalog == null) return;
    setState(() => _catalogLoading = true);
    try {
      final data = await widget.loadCatalog!({
        'catalog_search': _catalogSearch,
        if (more && _catalogAfter != null) 'catalog_after': _catalogAfter,
      });
      if (!mounted) return;
      final incoming = (data['products'] as List? ?? [])
          .map((p) => Map<String, dynamic>.from(p as Map))
          .toList();
      final items = (data['supplier_items'] as List? ?? [])
          .map((p) => Map<String, dynamic>.from(p as Map))
          .toList();
      setState(() {
        final selected = _lines.map((l) => l['product_id']).toSet();
        _products = {
          for (final p in [
            ..._products.where((p) => more || selected.contains(p['id'])),
            ...incoming,
          ])
            p['id']: p,
        }.values.toList();
        final ids = _products.map((p) => p['id']).toSet();
        _supplierItems = {
          for (final i in [
            ..._supplierItems.where((i) => ids.contains(i['product_id'])),
            ...items,
          ])
            i['id']: i,
        }.values.toList();
        _catalogAfter = incoming.lastOrNull?['id']?.toString();
        _catalogHasMore = data['catalog_has_more'] == true;
      });
    } catch (_) {
      if (mounted) setState(() => _saveError = copy('saveFailed'));
    } finally {
      if (mounted) setState(() => _catalogLoading = false);
    }
  }

  num? _estimate(Map<String, dynamic> line) {
    final product = _products
        .where((p) => p['id'] == line['product_id'])
        .firstOrNull;
    final item = procurementEstimateItem(
      _supplierItems,
      line['product_id'] as String?,
      line['preferred_supplier_id'] as String?,
    );
    num n(dynamic v) => v is num ? v : num.tryParse(v?.toString() ?? '') ?? 0;
    if (product == null ||
        item == null ||
        item['unit_price'] == null ||
        n(item['order_unit_quantity_base']) <= 0) {
      return null;
    }
    final net =
        n(line['quantity']) *
        (line['unit'] == product['base_unit'] ? 1 : n(product['conversion'])) /
        n(item['order_unit_quantity_base']) *
        n(item['unit_price']);
    return num.parse(net.toStringAsFixed(2)) +
        num.parse((net * n(item['tax_rate']) / 100).toStringAsFixed(2));
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('구매요청', 'Purchase request', 'Yêu cầu mua hàng')),
    content: SizedBox(
      width: 700,
      child: SingleChildScrollView(
        child: ExcludeFocus(
          excluding: _saving || _needsConfirmation,
          child: AbsorbPointer(
            absorbing: _saving || _needsConfirmation,
            child: Form(
              key: _form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${copy('expectedTotal')}: ${_lines.any((l) => _estimate(l) == null) ? copy('quoteNeeded') : procurementNumber(_lines.fold<num>(0, (sum, l) => sum + _estimate(l)!))} VND',
                  ),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    initialValue: _category == 'stationery'
                        ? 'tools'
                        : _category,
                    decoration: InputDecoration(labelText: copy('category')),
                    items: [
                      for (final k in [
                        'raw_material',
                        'tools',
                        'beverage',
                        'other',
                      ])
                        DropdownMenuItem(value: k, child: Text(copy(k))),
                    ],
                    onChanged: (v) => setState(() => _category = v!),
                  ),
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
                        '필요일 (YYYY-MM-DD)',
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
                  if (widget.loadCatalog != null)
                    TextField(
                      decoration: InputDecoration(
                        labelText: copy('searchCatalog'),
                      ),
                      onSubmitted: _saving
                          ? null
                          : (value) {
                              _catalogSearch = value.trim();
                              _loadCatalog();
                            },
                    ),
                  if (_catalogLoading) const LinearProgressIndicator(),
                  if (_catalogHasMore && widget.loadCatalog != null)
                    TextButton(
                      onPressed: _catalogLoading || _saving
                          ? null
                          : () => _loadCatalog(more: true),
                      child: Text(copy('moreCatalog')),
                    ),
                  if (_saveError != null)
                    Text(
                      _saveError!,
                      style: const TextStyle(color: Colors.red),
                    ),
                  if (_needsConfirmation)
                    Text(
                      t(
                        '저장 여부를 확인해야 합니다. 아래 버튼으로 같은 요청을 재시도하세요.',
                        'Saving needs confirmation. Use the button below to retry the same request.',
                        'Cần xác nhận việc lưu. Dùng nút bên dưới để thử lại cùng yêu cầu.',
                      ),
                    ),
                  for (final line in _lines)
                    Padding(
                      key: ValueKey(line['_key']),
                      padding: const EdgeInsets.only(top: 16),
                      child: Column(
                        children: [
                          DropdownButtonFormField<String>(
                            isExpanded: true,
                            initialValue: line['product_id'] as String?,
                            decoration: InputDecoration(
                              labelText: t('품목', 'Item', 'Mặt hàng'),
                            ),
                            items: _products
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
                              line['unit'] = _products.firstWhere(
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
                                    labelText: t(
                                      '필요 수량',
                                      'Quantity',
                                      'Số lượng',
                                    ),
                                  ),
                                  onChanged: (s) =>
                                      setState(() => line['quantity'] = s),
                                  validator: (s) =>
                                      s != null &&
                                          RegExp(
                                            r'^\d+(\.\d{1,3})?$',
                                          ).hasMatch(s) &&
                                          (double.tryParse(s) ?? 0) > 0 &&
                                          (double.tryParse(s)?.isFinite ??
                                              false)
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
                                  isExpanded: true,
                                  key: ValueKey(
                                    '${line['_key']}:${line['product_id']}',
                                  ),
                                  initialValue: line['unit'] as String?,
                                  decoration: InputDecoration(
                                    labelText: t('단위', 'Unit', 'Đơn vị'),
                                  ),
                                  items: _products
                                      .where(
                                        (p) => p['id'] == line['product_id'],
                                      )
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
                                  onChanged: (u) =>
                                      setState(() => line['unit'] = u),
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
                                tooltip: t(
                                  '품목 삭제',
                                  'Remove item',
                                  'Xóa mặt hàng',
                                ),
                              ),
                            ],
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
                      () => _lines.add({
                        '_key': const Uuid().v4(),
                        'quantity': '1',
                      }),
                    ),
                    icon: const Icon(Icons.add),
                    label: Text(t('품목 추가', 'Add item', 'Thêm mặt hàng')),
                  ),
                ],
              ),
            ),
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
        onPressed: _saving
            ? null
            : () async {
                if (_saving) return;
                if (!_form.currentState!.validate()) return;
                final payload = <String, dynamic>{
                  'purchase_category': _category,
                  'purchase_channel': _channel,
                  'reason': _reason.text.trim(),
                  'requested_delivery_date': _date.text,
                  'memo': _memo.text,
                  'lines': _lines
                      .map((l) => Map<String, dynamic>.from(l)..remove('_key'))
                      .toList(),
                };
                if (widget.saveRequest == null) {
                  Navigator.pop(context, payload);
                  return;
                }
                setState(() {
                  _saving = true;
                  _saveError = null;
                });
                FocusScope.of(context).unfocus();
                try {
                  final error = _needsConfirmation
                      ? await widget.retrySavedRequest!()
                      : await widget.saveRequest!(payload);
                  if (!context.mounted) return;
                  if (error == null) {
                    Navigator.pop(context, payload);
                  } else {
                    setState(() {
                      _saveError = error;
                      _needsConfirmation =
                          widget.needsConfirmation?.call() == true;
                    });
                  }
                } catch (_) {
                  if (mounted) {
                    setState(() {
                      _saveError = copy('saveFailed');
                      _needsConfirmation =
                          widget.needsConfirmation?.call() == true;
                    });
                  }
                } finally {
                  if (mounted) setState(() => _saving = false);
                }
              },
        child: Text(
          _needsConfirmation
              ? t('같은 요청 재시도', 'Retry saved request', 'Thử lại')
              : t('저장', 'Save', 'Lưu'),
        ),
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
