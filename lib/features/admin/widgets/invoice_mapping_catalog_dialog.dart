import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../../main.dart';
import '../../restaurant_sales_export/invoice_mapping_service.dart';
import 'invoice_profile_editor.dart';
import 'invoice_mapping_import_dialog.dart';

/// The catalog is based on menu masters, including menus with no sales.
class InvoiceMappingCatalogDialog extends StatefulWidget {
  const InvoiceMappingCatalogDialog({
    super.key,
    this.taxEntityId,
    this.service,
  });
  final String? taxEntityId;
  final InvoiceMappingService? service;
  @override
  State<InvoiceMappingCatalogDialog> createState() =>
      _InvoiceMappingCatalogDialogState();
}

class _InvoiceMappingCatalogDialogState
    extends State<InvoiceMappingCatalogDialog> {
  late final _service =
      widget.service ??
      InvoiceMappingService(
        (name, params) => supabase.rpc(name, params: params),
      );
  late String? _entity = widget.taxEntityId;
  Map<String, dynamic>? _catalog;
  bool _busy = false;
  String? _error;
  DateTime? _effectiveDate;
  String copy(String ko, String vi, String en) =>
      switch (Localizations.localeOf(context).languageCode) {
        'vi' => vi,
        'en' => en,
        _ => ko,
      };
  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final data = await _service.catalog(taxEntityId: _entity);
      if (mounted) setState(() => _catalog = data);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _apply() async {
    final data = _catalog!;
    final rows = (data['rows'] as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _service.applyPolicy(
        rows,
        effectiveFrom: _effectiveDate == null
            ? data['server_time'] as String
            : '${_effectiveDate!.toIso8601String().substring(0, 10)}T00:00:00+07:00',
      );
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
      return;
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    await _load();
  }

  Future<void> _policy(Map<String, dynamic> store) async {
    final approved = await showDialog<bool>(
      context: context,
      builder: (_) => _InvoicePolicyDialog(
        store: store,
        taxEntityId: _entity!,
        rpc: _service.rpc,
      ),
    );
    if (approved == true && mounted) await _load();
  }

  Future<void> _edit(Map<String, dynamic> row) async {
    await showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text('${row['name_vi']}'),
        content: SingleChildScrollView(
          child: SizedBox(
            width: 500,
            child: InvoiceProfileEditor(
              item: {
                ...row,
                'invoice_name_vi': row['approved_name'] ?? row['name_vi'],
                'invoice_unit_name': row['suggested_unit'],
              },
              onSaved: () => Navigator.pop(context),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(copy('닫기', 'Đóng', 'Close')),
          ),
        ],
      ),
    );
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final data = _catalog;
    final rows = (data?['rows'] as List?) ?? [];
    final entities = (data?['entities'] as List?) ?? [];
    final stores = (data?['stores'] as List?) ?? [];
    return AlertDialog(
      title: Text(
        copy(
          '전체 메뉴 계산서 매핑',
          'Ánh xạ hóa đơn toàn bộ menu',
          'Full menu invoice mapping',
        ),
      ),
      content: SizedBox(
        width: 820,
        height: 560,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButton<String?>(
              key: const Key('invoice_catalog_entity'),
              value: data == null ? null : _entity,
              isExpanded: true,
              items: [
                DropdownMenuItem<String?>(
                  value: null,
                  child: Text(
                    copy('모든 법인', 'Tất cả pháp nhân', 'All legal entities'),
                  ),
                ),
                for (final entity in entities)
                  DropdownMenuItem<String?>(
                    value: entity['id'] as String,
                    child: Text('${entity['name']}'),
                  ),
              ],
              onChanged: _busy
                  ? null
                  : (value) {
                      setState(() => _entity = value);
                      _load();
                    },
            ),
            if (data != null)
              Text(
                '${copy('등록 메뉴', 'Món đã đăng ký', 'Registered menus')} ${data['total_count']} · '
                '${copy('매핑 완료', 'Đã ánh xạ', 'Mapped')} ${data['mapped_count']} · '
                '${copy('확인 필요', 'Cần kiểm tra', 'Needs review')} ${data['missing_count']}',
                key: const Key('invoice_catalog_counts'),
              ),
            if (_entity != null)
              Wrap(
                spacing: 8,
                children: [
                  for (final store in stores)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () => _policy(
                              Map<String, dynamic>.from(store as Map),
                            ),
                      child: Text(
                        '${store['store_name']} · ${copy('자동 매핑 정책', 'Chính sách tự động', 'Automatic mapping policy')}',
                      ),
                    ),
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () async {
                            final now = DateTime.now().toUtc().add(
                              const Duration(hours: 7),
                            );
                            final day = await showDatePicker(
                              context: context,
                              initialDate: _effectiveDate ?? now,
                              firstDate: DateTime(2020),
                              lastDate: now,
                            );
                            if (day != null && mounted) {
                              setState(() => _effectiveDate = day);
                            }
                          },
                    child: Text(
                      _effectiveDate == null
                          ? copy(
                              '적용 시점: 현재',
                              'Áp dụng từ hiện tại',
                              'Effective from now',
                            )
                          : '${copy('과거 적용일', 'Ngày áp dụng trước đây', 'Historical effective date')}: ${_effectiveDate!.toIso8601String().substring(0, 10)}',
                    ),
                  ),
                ],
              ),
            if (_effectiveDate != null)
              Text(
                copy(
                  '과거 적용에는 정책의 실제 승인 근거가 사용됩니다. 발행·외부 신고 완료 자료는 보호됩니다.',
                  'Áp dụng trước đây sử dụng căn cứ chính sách đã duyệt. Bảo vệ hóa đơn đã phát hành và đã báo cáo.',
                  'Historical application uses the approved policy evidence. Issued and externally reported data remain protected.',
                ),
              ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            if (_busy) const LinearProgressIndicator(),
            Expanded(
              child: ListView.builder(
                itemCount: rows.length,
                itemBuilder: (_, index) {
                  final row = Map<String, dynamic>.from(rows[index] as Map);
                  final mapped = row['mapping_status'] == 'mapped';
                  return ListTile(
                    key: ValueKey('invoice_catalog_${row['id']}'),
                    leading: Icon(
                      mapped ? Icons.check_circle_outline : Icons.warning_amber,
                    ),
                    title: Text(
                      '${row['name_vi']} / ${row['suggested_unit'] ?? '—'}',
                    ),
                    subtitle: Text(
                      '${row['store_name']} · ${row['category_name']} · '
                      '${row['is_archived'] == true ? copy('보관', 'Lưu trữ', 'Archived') : row['mapping_status']}\n'
                      '${row['profile_id'] ?? '—'} · ${row['effective_from'] ?? '—'} → ${row['effective_to'] ?? '∞'}',
                    ),
                    onTap: _busy ? null : () => _edit(row),
                  );
                },
              ),
            ),
          ],
        ),
      ),
      actions: [
        if (_entity != null)
          TextButton(
            onPressed: _busy
                ? null
                : () async {
                    await showDialog<int>(
                      context: context,
                      builder: (_) =>
                          InvoiceMappingImportDialog(taxEntityId: _entity!),
                    );
                    if (mounted) await _load();
                  },
            child: Text(copy('JSON 가져오기', 'Nhập JSON', 'Import JSON')),
          ),
        FilledButton(
          onPressed: _busy || data == null || rows.isEmpty ? null : _apply,
          child: Text(
            copy(
              '승인된 정책으로 전체 매핑',
              'Ánh xạ tất cả theo chính sách đã duyệt',
              'Map all with approved policies',
            ),
          ),
        ),
        TextButton(
          onPressed: _busy ? null : () => Navigator.pop(context),
          child: Text(copy('닫기', 'Đóng', 'Close')),
        ),
      ],
    );
  }
}

class _InvoicePolicyDialog extends StatefulWidget {
  const _InvoicePolicyDialog({
    required this.store,
    required this.taxEntityId,
    required this.rpc,
  });
  final Map<String, dynamic> store;
  final String taxEntityId;
  final Future<dynamic> Function(String, Map<String, dynamic>) rpc;
  @override
  State<_InvoicePolicyDialog> createState() => _InvoicePolicyDialogState();
}

class _InvoicePolicyDialogState extends State<_InvoicePolicyDialog> {
  final _version = 'POS-policy-${const Uuid().v4()}';
  final _reference = TextEditingController();
  final _combo = TextEditingController(text: 'Bộ');
  final _units = <String, TextEditingController>{};
  bool _busy = false;
  String? _error;
  Map<String, dynamic>? _request;
  String copy(String ko, String vi, String en) =>
      switch (Localizations.localeOf(context).languageCode) {
        'vi' => vi,
        'en' => en,
        _ => ko,
      };
  @override
  void initState() {
    super.initState();
    final policy = widget.store['policy'] as Map?;
    final rules = policy?['rules'] as Map?;
    _combo.text = rules?['combo_unit']?.toString() ?? 'Bộ';
    for (final c in widget.store['categories'] as List? ?? []) {
      _units[c['id'] as String] = TextEditingController(
        text: (rules?['category_units'] as Map?)?[c['id']]?.toString() ?? '',
      );
    }
  }

  @override
  void dispose() {
    _reference.dispose();
    _combo.dispose();
    for (final controller in _units.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _approve() async {
    if (_reference.text.trim().isEmpty ||
        _combo.text.trim().isEmpty ||
        _units.values.any((u) => u.text.trim().isEmpty)) {
      setState(
        () => _error = copy(
          '근거와 모든 실제 단위를 입력하세요.',
          'Nhập căn cứ và tất cả đơn vị thực tế.',
          'Enter evidence and every actual unit.',
        ),
      );
      return;
    }
    _request ??= {
      'p_store_id': widget.store['store_id'],
      'p_tax_entity_id': widget.taxEntityId,
      'p_policy_version': _version,
      'p_source_reference': _reference.text.trim(),
      'p_rules': {
        'category_units': {
          for (final e in _units.entries) e.key: e.value.text.trim(),
        },
        'combo_unit': _combo.text.trim(),
        'menu_units':
            ((widget.store['policy'] as Map?)?['rules']
                as Map?)?['menu_units'] ??
            {},
      },
    };
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.rpc('approve_invoice_mapping_policy', _request!);
      if (mounted) Navigator.pop(context, true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      '${widget.store['store_name']} · ${copy('자동 매핑 정책 승인', 'Duyệt chính sách tự động', 'Approve automatic mapping policy')}',
    ),
    content: SizedBox(
      width: 580,
      height: 480,
      child: ListView(
        children: [
          Text(
            copy(
              '등록된 베트남어 메뉴명을 사용합니다. 실제 판매 단위를 확인하고 승인하세요.',
              'Sử dụng tên tiếng Việt đã đăng ký. Xác nhận đơn vị bán thực tế trước khi duyệt.',
              'Uses registered Vietnamese menu names. Review actual sales units before approval.',
            ),
          ),
          for (final c in widget.store['categories'] as List? ?? [])
            TextField(
              enabled: !_busy,
              controller: _units[c['id']],
              maxLength: 40,
              onChanged: (_) => _request = null,
              decoration: InputDecoration(
                labelText: '${c['name_vi']} · ${copy('단위', 'Đơn vị', 'Unit')}',
              ),
            ),
          TextField(
            enabled: !_busy,
            controller: _combo,
            maxLength: 40,
            onChanged: (_) => _request = null,
            decoration: InputDecoration(
              labelText: copy('콤보 단위', 'Đơn vị combo', 'Combo unit'),
            ),
          ),
          TextField(
            enabled: !_busy,
            controller: _reference,
            maxLength: 350,
            onChanged: (_) => _request = null,
            decoration: InputDecoration(
              labelText: copy('승인 근거', 'Căn cứ phê duyệt', 'Approval evidence'),
            ),
          ),
          if (_error != null) Text(_error!),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: Text(copy('닫기', 'Đóng', 'Close')),
      ),
      FilledButton(
        onPressed: _busy ? null : _approve,
        child: Text(copy('정책 승인', 'Duyệt chính sách', 'Approve policy')),
      ),
    ],
  );
}
