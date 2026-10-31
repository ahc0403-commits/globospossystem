import 'procurement_reference_picker.dart';
import '../procurement/inventory_lot_workspace.dart';
import 'quality_profile_editor.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import '../../core/services/pos_backend.dart';

class StoreProcurementSetupService {
  StoreProcurementSetupService({SupabaseClient? client}) : _client = client;
  final SupabaseClient? _client;
  Future<dynamic> call(String name, Map<String, dynamic> params) =>
      (_client ?? supabase).rpc(name, params: params);
}

class StoreProcurementSetupCard extends StatefulWidget {
  const StoreProcurementSetupCard({
    super.key,
    required this.storeId,
    this.service,
  });
  final String storeId;
  final StoreProcurementSetupService? service;
  @override
  State<StoreProcurementSetupCard> createState() =>
      _StoreProcurementSetupCardState();
}

class _StoreProcurementSetupCardState extends State<StoreProcurementSetupCard> {
  late final _service = widget.service ?? StoreProcurementSetupService();
  Map<String, dynamic>? _data;
  bool _busy = false;
  String? _error;
  final _history = <String?>[null];
  String t(String ko, String vi, String en) =>
      switch (Localizations.localeOf(context).languageCode) {
        'ko' => ko,
        'vi' => vi,
        _ => en,
      };
  Future<void> _load() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final result = await _service.call('admin_get_procurement_setup_v1', {
        'p_store': widget.storeId,
        'p_after': _history.last,
        'p_limit': 100,
      });
      if (mounted) {
        setState(() => _data = Map<String, dynamic>.from(result as Map));
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = t(
            '구매 준비 정보를 불러오지 못했습니다.',
            'Không tải được thông tin chuẩn bị mua hàng.',
            'Could not load procurement readiness.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<Map<String, String>?> _form(
    String title,
    Map<String, String> fields, {
    Map<String, String> initial = const {},
    Set<String> optional = const {},
  }) async {
    final values = {...initial};
    return showDialog<Map<String, String>>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(title),
          content: SizedBox(
            width: 560,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final entry in fields.entries)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: TextFormField(
                        initialValue: values[entry.key],
                        maxLength: entry.key == 'specification' ? 2000 : 500,
                        decoration: InputDecoration(
                          labelText:
                              '${entry.value}${optional.contains(entry.key) ? '' : ' *'}',
                        ),
                        onChanged: (v) =>
                            update(() => values[entry.key] = v.trim()),
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: Text(t('취소', 'Hủy', 'Cancel')),
            ),
            FilledButton(
              onPressed:
                  fields.keys.any(
                    (k) =>
                        !optional.contains(k) &&
                        (values[k] ?? '').trim().isEmpty,
                  )
                  ? null
                  : () => Navigator.pop(context, values),
              child: Text(
                t(
                  '검토한 내용 승인',
                  'Phê duyệt nội dung đã kiểm tra',
                  'Approve reviewed values',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _write(String rpc, Map<String, dynamic> params) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _service.call(rpc, params);
      await _load();
    } catch (_) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = t(
            '저장하지 못했습니다. 값·권한·최신 버전을 확인한 후 다시 조회하십시오.',
            'Không lưu được. Kiểm tra dữ liệu, quyền và phiên bản rồi tải lại.',
            'Could not save. Check values, permissions and the latest version, then refresh.',
          );
        });
      }
    }
  }

  Future<void> _template() async {
    final values = await _form(
      t(
        '구매 정책 버전 승인',
        'Phê duyệt phiên bản chính sách mua',
        'Approve procurement policy version',
      ),
      {
        'name': t('정책 이름', 'Tên chính sách', 'Policy name'),
        'hours': t(
          '재고 조사 유효 시간 (1~720시간)',
          'Thời hạn kiểm kê (1–720 giờ)',
          'Stock freshness (1–720 hours)',
        ),
        'high': t(
          '고액 검토 기준 (VND, 선택)',
          'Ngưỡng giá trị cao (VND, tùy chọn)',
          'High value review (VND, optional)',
        ),
        'price': t(
          '가격 상승 검토율 (%, 선택)',
          'Ngưỡng tăng giá (%, tùy chọn)',
          'Price increase review (%, optional)',
        ),
        'quantity': t(
          '수량 검토 배수 (1 이상, 선택)',
          'Hệ số kiểm tra số lượng (≥1, tùy chọn)',
          'Quantity review multiplier (≥1, optional)',
        ),
      },
      optional: {'high', 'price', 'quantity'},
    );
    if (values == null || !mounted) return;
    final hours = int.tryParse(values['hours'] ?? '');
    if (hours == null ||
        hours < 1 ||
        hours > 720 ||
        ['high', 'price', 'quantity'].any(
          (k) =>
              (values[k] ?? '').isNotEmpty &&
              (double.tryParse(values[k]!)?.isFinite != true),
        )) {
      setState(
        () => _error = t(
          '시간과 숫자 기준을 확인하십시오.',
          'Kiểm tra thời hạn và các số liệu.',
          'Check hours and numeric criteria.',
        ),
      );
      return;
    }
    await _write('admin_publish_procurement_template_v1', {
      'p_id': const Uuid().v4(),
      'p_family': const Uuid().v4(),
      'p_expected_revision': 0,
      'p_name': values['name'],
      'p_policy': {
        'stock_freshness_hours': hours,
        if ((values['high'] ?? '').isNotEmpty)
          'high_value_amount': double.parse(values['high']!),
        if ((values['price'] ?? '').isNotEmpty)
          'max_price_increase_percent': double.parse(values['price']!),
        if ((values['quantity'] ?? '').isNotEmpty)
          'quantity_review_multiplier': double.parse(values['quantity']!),
      },
    });
  }

  Future<Map?> _reference(String kind, {String? unit}) => showDialog<Map>(
    context: context,
    builder: (_) => ProcurementReferencePicker(
      title: kind == 'specs'
          ? t(
              '승인 규격 검색',
              'Tìm quy cách đã duyệt',
              'Find approved specification',
            )
          : t('승인 정책 검색', 'Tìm chính sách đã duyệt', 'Find approved policy'),
      unit: unit,
      load: (after, search) async => Map<String, dynamic>.from(
        await _service.call('admin_procurement_reference_page_v1', {
              'p_kind': kind,
              'p_after': after,
              'p_search': search,
            })
            as Map,
      ),
    ),
  );
  Future<void> _applyReference() async {
    final value = await _reference('templates');
    if (value == null || !mounted) return;
    await _write('admin_apply_procurement_template_v1', {
      'p_store': widget.storeId,
      'p_template': value['id'],
      'p_expected_revision': (_data?['readiness'] as Map?)?['revision'] ?? 0,
    });
  }

  Future<void> _approveProduct(Map product) async {
    final suppliers = (product['suppliers'] as List).cast<Map>();
    final specs = (_data!['specs'] as List)
        .cast<Map>()
        .where((s) => s['base_unit'] == product['base_unit'])
        .toList();
    String? supplier = suppliers.firstOrNull?['id'].toString();
    String? spec = specs
        .where((s) => s['code'] == product['product_code'])
        .firstOrNull?['id']
        .toString();
    var evidence = '', until = '';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            t(
              '품목·구매 조건 승인',
              'Phê duyệt hàng và điều kiện mua',
              'Approve item and purchase terms',
            ),
          ),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '${product['product_code']} · ${product['name']}\n${product['specification']}\n1 ${product['stock_unit']} = ${product['base_unit_factor']} ${product['base_unit']}',
                  ),
                  DropdownButtonFormField<String>(
                    initialValue: supplier,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: t(
                        '공급업체·구매 단위',
                        'Nhà cung cấp/đơn vị mua',
                        'Supplier and purchase unit',
                      ),
                    ),
                    items: [
                      for (final s in suppliers)
                        DropdownMenuItem(
                          value: s['id'].toString(),
                          child: Text(
                            '${s['supplier_name']} · 1 ${s['order_unit']} = ${s['order_unit_quantity_base']} ${product['base_unit']} · ${s['unit_price']} VND',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => update(() => supplier = v),
                  ),
                  TextButton(
                    onPressed: () async {
                      final value = await _reference(
                        'specs',
                        unit: product['base_unit'].toString(),
                      );
                      if (value == null || !context.mounted) return;
                      update(() {
                        if (!specs.any((s) => s['id'] == value['id'])) {
                          specs.add(value);
                        }
                        spec = value['id'].toString();
                      });
                    },
                    child: Text(
                      t(
                        '전체 규격 검색',
                        'Tìm tất cả quy cách',
                        'Search all specifications',
                      ),
                    ),
                  ),
                  DropdownButtonFormField<String>(
                    key: ValueKey(spec),
                    initialValue: spec,
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: t(
                        '승인 규격 버전',
                        'Phiên bản quy cách đã duyệt',
                        'Approved specification version',
                      ),
                    ),
                    items: [
                      for (final s in specs)
                        DropdownMenuItem(
                          value: s['id'].toString(),
                          child: Text(
                            '${s['code']} v${s['revision']} · ${s['name']}',
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (v) => update(() => spec = v),
                  ),
                  TextField(
                    maxLength: 500,
                    decoration: InputDecoration(
                      labelText: t(
                        '공급업체 규격·가격 근거',
                        'Bằng chứng quy cách/giá',
                        'Specification and price evidence',
                      ),
                    ),
                    onChanged: (v) => update(() => evidence = v.trim()),
                  ),
                  TextField(
                    decoration: InputDecoration(
                      labelText: t(
                        '유효 종료일 (YYYY-MM-DD, 선택)',
                        'Ngày hết hiệu lực (YYYY-MM-DD, tùy chọn)',
                        'Valid through date (YYYY-MM-DD, optional)',
                      ),
                    ),
                    onChanged: (v) => update(() => until = v.trim()),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(t('취소', 'Hủy', 'Cancel')),
            ),
            FilledButton(
              onPressed:
                  supplier == null ||
                      spec == null ||
                      evidence.isEmpty ||
                      (until.isNotEmpty && DateTime.tryParse(until) == null)
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(t('승인', 'Phê duyệt', 'Approve')),
            ),
          ],
        ),
      ),
    );
    if (accepted != true || !mounted) return;
    await _write('admin_approve_procurement_catalog_v1', {
      'p_store': widget.storeId,
      'p_rows': [
        {
          'id': const Uuid().v4(),
          'product_id': product['id'],
          'supplier_item_id': supplier,
          'spec_id': spec,
          'valid_from': DateTime.now().toUtc().toIso8601String(),
          'valid_until': until.isEmpty ? null : '${until}T23:59:59+07:00',
          'source_reference': evidence,
        },
      ],
    });
  }

  Future<void> _spec(Map product) async {
    final values = await _form(
      t(
        '공통 원재료 규격 승인',
        'Phê duyệt quy cách nguyên liệu',
        'Approve common material specification',
      ),
      {
        'code': t('규격 코드', 'Mã quy cách', 'Specification code'),
        'name': t('이름', 'Tên', 'Name'),
        'specification': t(
          '검증된 규격',
          'Quy cách đã xác minh',
          'Verified specification',
        ),
      },
      initial: {
        'code': product['product_code']?.toString() ?? '',
        'name': product['name'].toString(),
        'specification': product['specification'].toString(),
      },
    );
    if (values == null || !mounted) return;
    final references = Map<String, dynamic>.from(
      await _service.call('admin_procurement_reference_page_v1', {
            'p_kind': 'specs',
            'p_search': values['code'],
            'p_after': null,
          })
          as Map,
    );
    final revisions =
        (references['rows'] as List)
            .cast<Map>()
            .where((s) => s['code'] == values['code'])
            .map((s) => (s['revision'] as num).toInt())
            .toList()
          ..sort();
    await _write('admin_publish_material_spec_v1', {
      'p_id': const Uuid().v4(),
      'p_code': values['code'],
      'p_expected_revision': revisions.lastOrNull ?? 0,
      'p_name': values['name'],
      'p_base_unit': product['base_unit'],
      'p_specification': values['specification'],
    });
  }

  Future<void> _initialPlan(Map product) async {
    final values = await _form(
      t(
        '초기 구매 계획 승인',
        'Duyệt kế hoạch mua ban đầu',
        'Approve initial purchase plan',
      ),
      {
        'quantity':
            '${t('승인 수량', 'Số lượng duyệt', 'Approved quantity')} (${product['base_unit']})',
        'until': t(
          '유효 종료일 YYYY-MM-DD',
          'Ngày hết hạn YYYY-MM-DD',
          'Valid through YYYY-MM-DD',
        ),
        'reason': t(
          '계획 근거·승인 사유',
          'Cơ sở và lý do phê duyệt',
          'Plan evidence and approval reason',
        ),
      },
    );
    if (values == null) return;
    final qty = num.tryParse(values['quantity'] ?? '');
    final until = DateTime.tryParse(values['until'] ?? '');
    if (qty == null ||
        !qty.isFinite ||
        qty < 0 ||
        until == null ||
        (values['reason'] ?? '').trim().length < 5) {
      if (mounted) {
        setState(
          () => _error = t(
            '수량·날짜·승인 근거를 확인하세요.',
            'Kiểm tra số lượng, ngày và căn cứ.',
            'Check quantity, date and approval evidence.',
          ),
        );
      }
      return;
    }
    await _write('admin_approve_initial_purchase_plan_v1', {
      'p_id': const Uuid().v4(),
      'p_store': widget.storeId,
      'p_rows': [
        {
          'product_id': product['id'],
          'quantity_base': qty,
          'base_unit': product['base_unit'],
        },
      ],
      'p_valid_until': values['until'],
      'p_reason': values['reason'],
    });
  }

  @override
  Widget build(BuildContext context) {
    final readiness = _data?['readiness'] as Map?;
    final checks = readiness?['checks'] as Map? ?? {};
    final products = (_data?['products'] as List? ?? []).cast<Map>();
    final labels = {
      'identity_transfer_review': t(
        '소속 이전 후 구매 기준 재승인',
        'Duyệt lại tiêu chuẩn sau chuyển',
        'Reapprove purchasing after ownership transfer',
      ),
      'store_open_for_procurement': t(
        '구매 가능한 매장',
        'Cửa hàng được mua hàng',
        'Store accepts procurement',
      ),
      'policy': t(
        '승인 정책 버전',
        'Phiên bản chính sách',
        'Approved policy version',
      ),
      'requester': t('요청 담당', 'Người đề nghị', 'Requester'),
      'store_manager': t('점장', 'Quản lý cửa hàng', 'Store manager'),
      'receiver': t('입고 담당', 'Người nhận hàng', 'Receiver'),
      'verifier': t('검수 권한', 'Quyền kiểm nhận', 'Inspection authority'),
      'buyer': t('구매 담당', 'Người mua', 'Buyer'),
      'accounting': t('회계 담당', 'Kế toán', 'Accounting'),
      'office_connected': t('Office 연결', 'Kết nối Office', 'Office connected'),
      'quality': t(
        '승인된 품질 기준',
        'Tiêu chí chất lượng đã duyệt',
        'Approved quality criteria',
      ),
      'catalog': t(
        '품목·공급업체·단위·가격 근거',
        'Hàng, nhà cung cấp, đơn vị và giá',
        'Catalog, suppliers, units and price evidence',
      ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              t('구매 준비', 'Chuẩn bị mua hàng', 'Procurement readiness'),
              style: Theme.of(context).textTheme.titleLarge,
            ),
            Text(
              t(
                '영업 개점 전에도 준비가 완료되면 발주·입고할 수 있습니다. 기존 매장은 명시적으로 기준을 적용합니다.',
                'Có thể mua và nhận hàng trước khai trương khi đã sẵn sàng. Cửa hàng hiện tại chủ động áp dụng tiêu chuẩn mới.',
                'Prepared stores can buy and receive before opening. Existing stores explicitly activate the new criteria.',
              ),
            ),
            if (_busy) const LinearProgressIndicator(),
            if (_error != null) Text(_error!),
            OutlinedButton(
              onPressed: _busy ? null : _load,
              child: Text(
                t(
                  '구매 준비 조회',
                  'Kiểm tra chuẩn bị',
                  'Check procurement readiness',
                ),
              ),
            ),
            OutlinedButton.icon(
              onPressed: _busy
                  ? null
                  : () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => InventoryLotWorkspace(
                          storeId: widget.storeId,
                          admin: true,
                          call: _service.call,
                        ),
                      ),
                    ),
              icon: const Icon(Icons.inventory_2_outlined),
              label: Text(
                t(
                  '재고·로트·초기 실사',
                  'Tồn kho, lô và kiểm kê đầu kỳ',
                  'Stock, lots and opening count',
                ),
              ),
            ),
            if (_data != null) ...[
              for (final check in checks.entries)
                ListTile(
                  dense: true,
                  leading: Icon(
                    check.value == true
                        ? Icons.check_circle_outline
                        : Icons.pending_outlined,
                  ),
                  title: Text(labels[check.key] ?? check.key.toString()),
                ),
              Wrap(
                spacing: 8,
                children: [
                  TextButton(
                    onPressed: _busy ? null : _template,
                    child: Text(
                      t(
                        '정책 버전 승인',
                        'Phê duyệt chính sách',
                        'Approve policy version',
                      ),
                    ),
                  ),
                  OutlinedButton(
                    onPressed: _busy ? null : _applyReference,
                    child: Text(
                      t(
                        '승인 정책 선택',
                        'Chọn chính sách đã duyệt',
                        'Choose approved policy',
                      ),
                    ),
                  ),
                  if (readiness?['enforced'] != true)
                    FilledButton(
                      onPressed: _busy || readiness?['ready'] != true
                          ? null
                          : () => _write(
                              'admin_activate_procurement_profile_v1',
                              {
                                'p_store': widget.storeId,
                                'p_expected_revision': readiness!['revision'],
                              },
                            ),
                      child: Text(
                        t(
                          '검증한 구매 기준 적용',
                          'Áp dụng tiêu chuẩn đã kiểm tra',
                          'Activate verified criteria',
                        ),
                      ),
                    ),
                ],
              ),
              for (final product in products)
                ListTile(
                  title: Text(
                    '${product['product_code'] ?? ''} · ${product['name']}',
                  ),
                  subtitle: Text(
                    '${product['receipt_classification']} · 1 ${product['stock_unit']} = ${product['base_unit_factor']} ${product['base_unit']}',
                  ),
                  trailing: Wrap(
                    children: [
                      IconButton(
                        tooltip: t(
                          '품질 기준 승인',
                          'Duyệt tiêu chí chất lượng',
                          'Approve quality criteria',
                        ),
                        icon: const Icon(Icons.science_outlined),
                        onPressed: _busy
                            ? null
                            : () => editQualityProfile(
                                context,
                                storeId: widget.storeId,
                                product: product,
                                save: _write,
                              ),
                      ),
                      IconButton(
                        tooltip: t(
                          '초기 구매 계획 승인',
                          'Duyệt kế hoạch ban đầu',
                          'Approve initial purchase plan',
                        ),
                        icon: const Icon(Icons.event_note_outlined),
                        onPressed: _busy ? null : () => _initialPlan(product),
                      ),
                      IconButton(
                        tooltip: t(
                          '규격 승인',
                          'Duyệt quy cách',
                          'Approve specification',
                        ),
                        icon: const Icon(Icons.description_outlined),
                        onPressed: _busy ? null : () => _spec(product),
                      ),
                      IconButton(
                        tooltip: t(
                          '구매 조건 승인',
                          'Duyệt điều kiện mua',
                          'Approve purchase terms',
                        ),
                        icon: const Icon(Icons.fact_check_outlined),
                        onPressed: _busy
                            ? null
                            : () => _approveProduct(product),
                      ),
                    ],
                  ),
                ),
              Row(
                children: [
                  if (_history.length > 1)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              _history.removeLast();
                              _load();
                            },
                      child: Text(t('이전', 'Trước', 'Previous')),
                    ),
                  if (products.length == 100)
                    TextButton(
                      onPressed: _busy
                          ? null
                          : () {
                              _history.add(products.last['id'].toString());
                              _load();
                            },
                      child: Text(t('다음', 'Tiếp', 'Next')),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }
}
