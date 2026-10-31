import 'dart:convert';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show PostgrestException;
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../core/services/inventory_service.dart';
import '../../core/services/pos_backend.dart';
import 'inventory_lot_editor.dart';
import 'procurement_inspection_dialog.dart';

typedef InventoryLotRpc =
    Future<dynamic> Function(String, Map<String, dynamic>);

class InventoryLotWorkspace extends StatefulWidget {
  const InventoryLotWorkspace({
    super.key,
    required this.storeId,
    this.admin = false,
    this.call,
    this.persistenceKey,
  });
  final String storeId;
  final bool admin;
  final InventoryLotRpc? call;
  final String? persistenceKey;
  @override
  State<InventoryLotWorkspace> createState() => _InventoryLotWorkspaceState();
}

class _InventoryLotWorkspaceState extends State<InventoryLotWorkspace> {
  Map<String, dynamic>? _data, _counts;
  final _lotPages = <String?>[null], _countPages = <String?>[null];
  bool _busy = false;
  String? _error, _pendingName;
  Map<String, dynamic>? _pending;
  String t(String ko, String en, String vi) =>
      switch (Localizations.localeOf(context).languageCode) {
        'ko' => ko,
        'vi' => vi,
        _ => en,
      };
  Future<dynamic> call(String name, Map<String, dynamic> p) =>
      widget.call?.call(name, p) ?? supabase.rpc(name, params: p);
  List<Map<String, dynamic>> list(dynamic v) => (v as List? ?? [])
      .whereType<Map>()
      .map((v) => Map<String, dynamic>.from(v))
      .toList();
  @override
  void initState() {
    super.initState();
    _initialize();
  }

  String? _storageKey;
  Future<void> _initialize() async {
    _storageKey =
        widget.persistenceKey ??
        (widget.call != null || supabase.auth.currentUser == null
            ? null
            : 'inventory-lot-v1:${supabase.rest.url}:${supabase.auth.currentUser!.id}:${widget.storeId}');
    try {
      if (_storageKey != null) {
        final raw = (await SharedPreferences.getInstance()).getString(
          _storageKey!,
        );
        if (raw != null) {
          final saved = jsonDecode(raw) as Map;
          _pendingName = saved['method'] as String;
          _pending = Map<String, dynamic>.from(saved['params'] as Map);
        }
      }
      if (mounted) await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = t(
            '이전 요청 복구 실패. 다시 화면을 여세요.',
            'Could not restore the previous request. Reopen this screen.',
            'Không khôi phục được yêu cầu trước. Mở lại màn hình.',
          ),
        );
      }
    }
  }

  Future<void> _persist() async {
    if (_storageKey == null) return;
    final prefs = await SharedPreferences.getInstance();
    final ok = _pending == null
        ? await prefs.remove(_storageKey!)
        : await prefs.setString(
            _storageKey!,
            jsonEncode({'method': _pendingName, 'params': _pending}),
          );
    if (!ok) throw StateError('INVENTORY_PENDING_PERSIST_FAILED');
  }

  Future<void> _guard(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = t(
            '자료나 첨부를 처리하지 못했습니다. 최신 자료를 확인하고 다시 시도하세요.',
            'Could not process the data or attachment. Review current data and retry.',
            'Không xử lý được dữ liệu hoặc tệp. Kiểm tra dữ liệu mới và thử lại.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final values = await Future.wait([
        call('inventory_lot_workspace_v1', {
          'p_store': widget.storeId,
          'p_after': _lotPages.last,
        }),
        if (widget.admin)
          call('admin_get_inventory_count_inputs_v1', {
            'p_store': widget.storeId,
            'p_after': _countPages.last,
          }),
      ]);
      if (mounted) {
        setState(() {
          _data = Map<String, dynamic>.from(values[0] as Map);
          if (widget.admin) {
            _counts = Map<String, dynamic>.from(values[1] as Map);
          }
        });
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = t(
            '재고 정보를 불러오지 못했습니다.',
            'Could not load stock information.',
            'Không tải được thông tin tồn kho.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _write(String name, Map<String, dynamic> p) async {
    _pendingName = name;
    _pending = p;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _persist();
      await call(name, p);
      if (_storageKey != null &&
          !await (await SharedPreferences.getInstance()).remove(_storageKey!)) {
        throw StateError('INVENTORY_PENDING_CLEAR_FAILED');
      }
      _pending = null;
      _pendingName = null;
      if (mounted) await _load();
    } on PostgrestException catch (e) {
      if (const {'P0001', '22023', '23514', '42501'}.contains(e.code)) {
        _pending = null;
        _pendingName = null;
        await _persist();
        if (mounted) {
          setState(
            () => _error = t(
              '서버가 요청을 거부했습니다. 최신 재고와 기준을 확인한 후 다시 입력하세요.',
              'The server rejected the request. Review current stock and criteria, then enter it again.',
              'Máy chủ từ chối yêu cầu. Kiểm tra tồn kho và tiêu chí mới rồi nhập lại.',
            ),
          );
        }
      } else {
        if (mounted) {
          setState(
            () => _error = t(
              '결과 미확인: 같은 요청을 다시 확인하세요.',
              'Result unconfirmed: retry the same request.',
              'Chưa xác nhận: thử lại cùng yêu cầu.',
            ),
          );
        }
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = t(
            '저장 결과를 확인하지 못했습니다. 같은 요청으로 다시 확인하거나 최신 재고를 조회하세요.',
            'Save was not confirmed. Retry the same request or review current stock.',
            'Chưa xác nhận lưu. Thử lại cùng yêu cầu hoặc kiểm tra tồn kho mới nhất.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<String, dynamic>?> _details(
    String title, {
    bool location = false,
    String? locationKind,
    bool quantity = false,
    num? maxQuantity,
  }) async {
    final form = GlobalKey<FormState>();
    final values = <String, dynamic>{};
    return showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: t(
                        '실제 작업 직원',
                        'Actual employee',
                        'Nhân viên thực tế',
                      ),
                    ),
                    items: [
                      for (final e in list(_data?['employees']))
                        DropdownMenuItem(
                          value: e['id'].toString(),
                          child: Text(e['name'].toString()),
                        ),
                    ],
                    onChanged: (v) => values['employee_id'] = v,
                    validator: (v) => v == null ? '*' : null,
                  ),
                  if (quantity)
                    TextFormField(
                      decoration: InputDecoration(
                        labelText:
                            '${t('기준 단위 수량', 'Base quantity', 'Số lượng cơ sở')} (≤$maxQuantity)',
                      ),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                      ),
                      onChanged: (v) => values['quantity'] = num.tryParse(v),
                      validator: (v) {
                        final n = num.tryParse(v ?? '');
                        return n != null &&
                                n.isFinite &&
                                n > 0 &&
                                n <= maxQuantity!
                            ? null
                            : '*';
                      },
                    ),
                  if (location)
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: t('이동할 위치', 'Destination', 'Vị trí đích'),
                      ),
                      items: [
                        for (final loc in list(_data?['locations']))
                          if (loc['kind'] == locationKind)
                            DropdownMenuItem(
                              value: loc['id'].toString(),
                              child: Text(loc['name'].toString()),
                            ),
                      ],
                      onChanged: (v) => values['location_id'] = v,
                      validator: (v) => v == null ? '*' : null,
                    ),
                  for (final entry in {
                    'reason': t('처리 사유', 'Reason', 'Lý do'),
                    'evidence_reference': t(
                      '확인 증거·문서 참조',
                      'Evidence / document reference',
                      'Bằng chứng / tham chiếu',
                    ),
                  }.entries)
                    TextFormField(
                      decoration: InputDecoration(labelText: entry.value),
                      maxLength: 500,
                      onChanged: (v) => values[entry.key] = v.trim(),
                      validator: (v) =>
                          (v?.trim().length ?? 0) < 5 ? '*' : null,
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
              if (form.currentState!.validate()) Navigator.pop(context, values);
            },
            child: Text(t('내용 확인', 'Review details', 'Kiểm tra nội dung')),
          ),
        ],
      ),
    );
  }

  Future<void> _location() async {
    final values = <String, dynamic>{};
    final form = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(
          t('보관 위치 등록', 'Add storage location', 'Thêm vị trí lưu trữ'),
        ),
        content: Form(
          key: form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                decoration: InputDecoration(labelText: t('이름', 'Name', 'Tên')),
                maxLength: 80,
                onChanged: (v) => values['name'] = v.trim(),
                validator: (v) => (v?.trim().isEmpty ?? true) ? '*' : null,
              ),
              DropdownButtonFormField<String>(
                decoration: InputDecoration(
                  labelText: t('용도', 'Purpose', 'Mục đích'),
                ),
                items: [
                  for (final e in {
                    'storage': t('사용 가능 재고', 'Available stock', 'Hàng sử dụng'),
                    'quarantine': t(
                      '검사 보류',
                      'Inspection hold',
                      'Tạm giữ kiểm tra',
                    ),
                    'rejected': t('불합격 격리', 'Rejected stock', 'Hàng không đạt'),
                  }.entries)
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
                ],
                onChanged: (v) => values['kind'] = v,
                validator: (v) => v == null ? '*' : null,
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(context, true);
            },
            child: Text(t('저장', 'Save', 'Lưu')),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await _write('admin_save_inventory_location_v1', {
      'p_id': const Uuid().v4(),
      'p_store': widget.storeId,
      'p_name': values['name'],
      'p_kind': values['kind'],
      'p_active': true,
      'p_expected_revision': 0,
    });
  }

  Future<void> _count(Map<String, dynamic> item) async {
    final data = Map<String, dynamic>.from(
      await call('inventory_lot_workspace_v1', {
            'p_store': widget.storeId,
            'p_ingredient': item['id'],
          })
          as Map,
    );
    if (!mounted) return;
    if (data['next_cursor'] != null ||
        list(data['lots']).any((l) => l['state'] != 'available')) {
      setState(
        () => _error = t(
          '보류·불합격 재고를 먼저 처리하세요. 한 번의 실사는 최대 50개 로트를 지원합니다.',
          'Resolve held/rejected stock first. One count supports up to 50 lots.',
          'Xử lý hàng tạm giữ/không đạt trước. Một lần kiểm kê hỗ trợ tối đa 50 lô.',
        ),
      );
      return;
    }
    final lots = list(data['lots'])
        .map(
          (l) => <String, dynamic>{
            'id': l['id'],
            'code': l['supplier_lot_code'],
            'expiry_date': l['expiry_date'],
            'location_id': l['location_id'],
            'quantity_base': l['quantity_base'],
          },
        )
        .toList();
    final values = <String, dynamic>{
      'track_lots': item['tracked'] == true,
      'acknowledge_unknown_legacy': false,
    };
    final started = DateTime.now().toUtc().toIso8601String();
    final form = GlobalKey<FormState>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            '${item['name']} · ${t('초기·정기 실사', 'Opening / stock count', 'Kiểm kê đầu kỳ / định kỳ')}',
          ),
          content: SizedBox(
            width: 650,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '${t('현재 원장', 'Current ledger', 'Sổ hiện tại')}: ${item['current_stock']} ${item['base_unit']}',
                    ),
                    DropdownButtonFormField<String>(
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: t(
                          '실사 직원',
                          'Counting employee',
                          'Nhân viên kiểm kê',
                        ),
                      ),
                      items: [
                        for (final e in list(_data?['employees']))
                          DropdownMenuItem(
                            value: e['id'].toString(),
                            child: Text(e['name'].toString()),
                          ),
                      ],
                      onChanged: (v) => values['employee'] = v,
                      validator: (v) => v == null ? '*' : null,
                    ),
                    for (final e in {
                      'actual': t(
                        '실제 수량 (0도 명시 입력)',
                        'Actual quantity (enter zero explicitly)',
                        'Số lượng thực (nhập rõ số 0)',
                      ),
                      'cost': t(
                        '실사 평가용 기준 단위 원가',
                        'Count valuation cost per base unit',
                        'Giá trị kiểm kê mỗi đơn vị cơ sở',
                      ),
                    }.entries)
                      TextFormField(
                        decoration: InputDecoration(labelText: e.value),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        onChanged: (v) => values[e.key] = num.tryParse(v),
                        validator: (v) {
                          final n = num.tryParse(v ?? '');
                          return n != null && n.isFinite && n >= 0 ? null : '*';
                        },
                      ),
                    for (final e in {
                      'source': t('원가 근거', 'Cost source', 'Nguồn giá vốn'),
                      'reason': t(
                        '실사 사유·증거',
                        'Count reason / evidence',
                        'Lý do / bằng chứng kiểm kê',
                      ),
                    }.entries)
                      TextFormField(
                        decoration: InputDecoration(labelText: e.value),
                        maxLength: 500,
                        onChanged: (v) => values[e.key] = v.trim(),
                        validator: (v) =>
                            (v?.trim().length ?? 0) < 5 ? '*' : null,
                      ),
                    CheckboxListTile(
                      title: Text(
                        t(
                          '로트 추적 적용 (승인 품질 기준 필요)',
                          'Enable lot tracking (approved criteria required)',
                          'Theo dõi lô (cần tiêu chí đã duyệt)',
                        ),
                      ),
                      value: values['track_lots'] == true,
                      onChanged: item['tracked'] == true
                          ? null
                          : (v) => update(() => values['track_lots'] = v),
                    ),
                    if (values['track_lots'] == true) ...[
                      CheckboxListTile(
                        title: Text(
                          t(
                            '기존 재고의 확인 불가 로트는 과거 미상으로 기록',
                            'Record unverifiable existing lots as historical unknown',
                            'Ghi lô cũ không xác minh là không rõ lịch sử',
                          ),
                        ),
                        value: values['acknowledge_unknown_legacy'] == true,
                        onChanged: (v) => update(
                          () => values['acknowledge_unknown_legacy'] = v,
                        ),
                      ),
                      InventoryLotEditor(
                        lots: lots,
                        locations: list(_data?['locations']),
                        countMode: true,
                        onChanged: () => update(() {}),
                      ),
                      FormField<bool>(
                        validator: (_) =>
                            ((values['actual'] as num? ?? -1) -
                                        lots.fold<num>(
                                          0,
                                          (sum, l) =>
                                              sum +
                                              (l['quantity_base'] as num? ?? 0),
                                        ))
                                    .abs() >
                                0.0001
                            ? t(
                                '로트 합계와 실사 수량을 맞추세요.',
                                'Lot total must match the count.',
                                'Tổng lô phải khớp kiểm kê.',
                              )
                            : null,
                        builder: (f) => Text(
                          f.errorText ?? '',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                          ),
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
              onPressed: () => Navigator.pop(context),
              child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) Navigator.pop(context, true);
              },
              child: Text(t('실사 확정', 'Confirm count', 'Xác nhận kiểm kê')),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    await _write('admin_record_inventory_lot_count_v1', {
      'p_id': const Uuid().v4(),
      'p_store': widget.storeId,
      'p_employee': values['employee'],
      'p_reason': values['reason'],
      'p_rows': [
        {
          'product_id': item['product_id'],
          'inventory_item_id': item['id'],
          'unit': item['base_unit'],
          'expected_stock': item['current_stock'] ?? 0,
          'actual_quantity_base': values['actual'],
          'unit_cost_base': values['cost'],
          'cost_source': values['source'],
          'counted_at': started,
          'track_lots': values['track_lots'],
          'acknowledge_unknown_legacy': values['acknowledge_unknown_legacy'],
          'lots': lots
              .where((l) => (l['quantity_base'] as num? ?? 0) > 0)
              .toList(),
        },
      ],
    });
  }

  Future<void> _dispose(Map<String, dynamic> lot, String action) async {
    final kind = action == 'release'
        ? 'storage'
        : action == 'reject'
        ? 'rejected'
        : switch (lot['state']) {
            'held' => 'quarantine',
            'rejected' => 'rejected',
            _ => 'storage',
          };
    final p = await _details(
      _action(action),
      quantity: true,
      maxQuantity: lot['quantity_base'] as num,
      location: ['release', 'reject', 'move'].contains(action),
      locationKind: kind,
    );
    if (p == null || !mounted) return;
    final quantity = p.remove('quantity');
    if (action == 'release') {
      final receipt = const Uuid().v4();
      final inspected = await showDialog<List<Map<String, dynamic>>>(
        context: context,
        barrierDismissible: false,
        builder: (_) => ProcurementInspectionDialog(
          releaseOnly: true,
          lines: [
            {
              'id': lot['purchase_order_line_id'],
              'product_name': lot['ingredient_name'],
              'quality': lot['quality'],
            },
          ],
          payload: [
            {
              'purchase_order_line_id': lot['purchase_order_line_id'],
              'received_quantity_base': quantity,
            },
          ],
          employees: list(_data?['employees']),
          uploadPhoto: (file) async =>
              InventoryService().uploadInventoryReceiptStatement(
                storeId: widget.storeId,
                receiptId: receipt,
                fileName: '${const Uuid().v4()}-${file.name}',
                bytes: await file.readAsBytes(),
                contentType: file.name.toLowerCase().endsWith('.png')
                    ? 'image/png'
                    : 'image/jpeg',
              ),
        ),
      );
      if (inspected == null || !mounted) return;
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Evidence',
            extensions: ['pdf', 'jpg', 'jpeg', 'png'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      final path = await InventoryService().uploadInventoryReceiptStatement(
        storeId: widget.storeId,
        receiptId: receipt,
        fileName: file.name,
        bytes: await file.readAsBytes(),
        contentType: file.name.toLowerCase().endsWith('.pdf')
            ? 'application/pdf'
            : file.name.toLowerCase().endsWith('.png')
            ? 'image/png'
            : 'image/jpeg',
      );
      p.addAll({
        'receipt_id': receipt,
        'expected_order_version': lot['order_version'],
        'inspection': inspected.single['inspection'],
        'employee_id': (inspected.single['inspection'] as Map)['employee_id'],
        'statement_storage_path': path,
      });
    }
    if (!mounted) return;
    await _write('inventory_dispose_lot_v1', {
      'p_id': const Uuid().v4(),
      'p_store': widget.storeId,
      'p_lot': lot['id'],
      'p_action': action,
      'p_quantity': quantity,
      'p_payload': p,
    });
  }

  String _action(String action) => switch (action) {
    'release' => t(
      '재검수 후 보류 해제',
      'Reinspect and release',
      'Kiểm tra lại và giải phóng',
    ),
    'reject' => t('불합격 확정', 'Reject', 'Xác nhận không đạt'),
    'return' => t(
      '공급업체 반송',
      'Return held / rejected stock',
      'Trả hàng tạm giữ / không đạt',
    ),
    'move' => t('위치 이동', 'Move location', 'Chuyển vị trí'),
    _ => t('폐기', 'Waste', 'Hủy'),
  };
  Widget _paging(Map<String, dynamic>? data, List<String?> pages) => Row(
    children: [
      if (pages.length > 1)
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  pages.removeLast();
                  _load();
                },
          child: Text(t('이전', 'Previous', 'Trước')),
        ),
      if (data?['next_cursor'] != null)
        TextButton(
          onPressed: _busy
              ? null
              : () {
                  pages.add(data!['next_cursor'].toString());
                  _load();
                },
          child: Text(t('다음', 'Next', 'Tiếp')),
        ),
    ],
  );
  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(t('재고·로트 관리', 'Stock and lots', 'Tồn kho và lô')),
      actions: [
        IconButton(
          onPressed: _busy ? null : _load,
          icon: const Icon(Icons.refresh),
        ),
      ],
    ),
    body: ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_busy) const LinearProgressIndicator(),
        if (_error != null) Text(_error!),
        if (_pending != null)
          FilledButton(
            onPressed: _busy ? null : () => _write(_pendingName!, _pending!),
            child: Text(
              t('같은 요청 재확인', 'Retry the same request', 'Thử lại cùng yêu cầu'),
            ),
          ),
        if (widget.admin) ...[
          OutlinedButton(
            onPressed: _busy || _pending != null
                ? null
                : () => _guard(_location),
            child: Text(
              t('보관 위치 등록', 'Add storage location', 'Thêm vị trí lưu trữ'),
            ),
          ),
          for (final item in list(_counts?['items']))
            ListTile(
              title: Text(
                '${item['name']} · ${item['current_stock'] ?? 0} ${item['base_unit'] ?? item['unit']}',
              ),
              subtitle: Text(
                item['last_count_at']?.toString() ??
                    t(
                      '초기 실사 미확인',
                      'Opening count not recorded',
                      'Chưa ghi kiểm kê đầu kỳ',
                    ),
              ),
              trailing: TextButton(
                onPressed:
                    _busy || _pending != null || item['product_id'] == null
                    ? null
                    : () => _guard(() => _count(item)),
                child: Text(t('실사', 'Count', 'Kiểm kê')),
              ),
            ),
          _paging(_counts, _countPages),
          const Divider(),
        ],
        for (final lot in list(_data?['lots']))
          Card(
            child: ListTile(
              title: Text(
                '${lot['ingredient_name']} · ${lot['supplier_lot_code'] ?? t('과거 미상', 'Historical unknown', 'Không rõ lịch sử')}',
              ),
              subtitle: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '${switch (lot['state']) {
                      'available' => t('사용 가능', 'Available', 'Có thể sử dụng'),
                      'held' => t('검사 보류', 'Inspection hold', 'Tạm giữ kiểm tra'),
                      'rejected' => t('불합격', 'Rejected', 'Không đạt'),
                      _ => t('상태 확인 필요', 'Review status', 'Kiểm tra trạng thái'),
                    }} · ${lot['quantity_base']} ${lot['unit']} · ${lot['expiry_date'] ?? '—'}',
                  ),
                  if (lot['purchase_order_no'] != null)
                    Text(lot['purchase_order_no'].toString()),
                  if (_data?['can_dispose'] == true)
                    Wrap(
                      children: [
                        for (final action in [
                          if (lot['state'] == 'held') ...['release', 'reject'],
                          if (lot['state'] != 'available') 'return',
                          'move',
                          'waste',
                        ])
                          TextButton(
                            onPressed: _busy || _pending != null
                                ? null
                                : () => _guard(() => _dispose(lot, action)),
                            child: Text(_action(action)),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ),
        _paging(_data, _lotPages),
      ],
    ),
  );
}
