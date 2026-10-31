import 'store_operational_acceptance_dialog.dart';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/services/pos_backend.dart';

class StoreLifecycleService {
  StoreLifecycleService([this.client]);
  final SupabaseClient? client;
  Future<Map<String, dynamic>> load(String store) async =>
      Map<String, dynamic>.from(
        await (client ?? supabase).rpc(
              'admin_get_store_lifecycle_v1',
              params: {'p_store_id': store},
            )
            as Map,
      );
  Future<Map<String, dynamic>> operationalInputs(String store) async =>
      Map<String, dynamic>.from(
        await (client ?? supabase).rpc(
              'admin_get_store_operational_inputs_v1',
              params: {'p_store': store},
            )
            as Map,
      );
  Future<Map<String, dynamic>> transferOptions(String store) async =>
      Map<String, dynamic>.from(
        await (client ?? supabase).rpc(
              'admin_get_store_transfer_options_v1',
              params: {'p_store': store},
            )
            as Map,
      );
  Future<void> write(String rpc, Map<String, dynamic> params) async {
    await (client ?? supabase).rpc(rpc, params: params);
  }
}

class StoreLifecycleCard extends StatefulWidget {
  const StoreLifecycleCard({super.key, required this.storeId, this.service});
  final String storeId;
  final StoreLifecycleService? service;
  @override
  State<StoreLifecycleCard> createState() => _StoreLifecycleCardState();
}

class _StoreLifecycleCardState extends State<StoreLifecycleCard> {
  Map<String, dynamic>? _data;
  bool _busy = false;
  String? _error;
  StoreLifecycleService get _service =>
      widget.service ?? StoreLifecycleService();
  String _text(String ko, String vi, String en) =>
      switch (Localizations.localeOf(context).languageCode) {
        'ko' => ko,
        'vi' => vi,
        _ => en,
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
      final data = await _service.load(widget.storeId);
      if (mounted) {
        setState(() => _data = Map<String, dynamic>.from(data as Map));
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _text(
            '준비 상태를 불러오지 못했습니다.',
            'Không tải được trạng thái.',
            'Could not load readiness.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _action(String action) async {
    final data = _data;
    if (_busy || data == null) return;
    final employees = (data['employees'] as List).cast<Map>();
    String? employee = employees.firstOrNull?['id']?.toString();
    var evidence = '';
    final accepted = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: Text(
            action == 'handover'
                ? _text(
                    '계정 인수 기록',
                    'Ghi nhận bàn giao tài khoản',
                    'Record account handover',
                  )
                : action == 'verification'
                ? _text(
                    '출력·조리·인계 검증 기록',
                    'Ghi nhận kiểm tra in, bếp và bàn giao',
                    'Record output, cooking and handoff verification',
                  )
                : _text(
                    '영업 상태 변경',
                    'Đổi trạng thái hoạt động',
                    'Change operating status',
                  ),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (action == 'handover')
                DropdownButtonFormField<String>(
                  initialValue: employee,
                  isExpanded: true,
                  decoration: InputDecoration(
                    labelText: _text(
                      '인수 직원',
                      'Nhân viên nhận',
                      'Receiving employee',
                    ),
                  ),
                  items: employees
                      .map(
                        (e) => DropdownMenuItem(
                          value: e['id'].toString(),
                          child: Text(e['name'].toString()),
                        ),
                      )
                      .toList(),
                  onChanged: (v) => update(() => employee = v),
                ),
              TextField(
                maxLength: 500,
                maxLines: 3,
                decoration: InputDecoration(
                  labelText: _text(
                    '검증·인수 증거 또는 변경 사유',
                    'Bằng chứng kiểm tra, bàn giao hoặc lý do',
                    'Verification, handover evidence or reason',
                  ),
                ),
                onChanged: (value) => update(() => evidence = value),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_text('취소', 'Hủy', 'Cancel')),
            ),
            FilledButton(
              onPressed:
                  evidence.trim().isEmpty ||
                      (action == 'handover' && employee == null)
                  ? null
                  : () => Navigator.pop(context, true),
              child: Text(_text('기록', 'Ghi nhận', 'Record')),
            ),
          ],
        ),
      ),
    );
    final reason = evidence.trim();
    if (accepted != true || !mounted) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (action == 'handover') {
        await _service.write('admin_record_store_handover_v1', {
          'p_request_id': const Uuid().v4(),
          'p_store_id': widget.storeId,
          'p_employee_id': employee,
          'p_evidence': reason,
        });
      } else if (action == 'verification') {
        await _service.write('admin_record_store_verification_v1', {
          'p_request_id': const Uuid().v4(),
          'p_store_id': widget.storeId,
          'p_source_hash': data['source_hash'],
          'p_evidence': reason,
        });
      } else if (action == 'reopen') {
        await _service.write('admin_prepare_store_reopening_v1', {
          'p_id': const Uuid().v4(),
          'p_store': widget.storeId,
          'p_expected_revision': (data['lifecycle'] as Map)['revision'],
          'p_reason': reason,
        });
      } else if (action == 'closed') {
        await _service.write('admin_close_store', {
          'p_store_id': widget.storeId,
          'p_reason': reason,
        });
      } else {
        await _service.write('admin_transition_store_lifecycle_v1', {
          'p_store_id': widget.storeId,
          'p_expected_revision': (data['lifecycle'] as Map)['revision'],
          'p_state': action,
          'p_source_hash': data['source_hash'],
          'p_reason': reason,
        });
      }
      await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _text(
            '상태가 변경됐거나 필수 준비가 남아 있습니다. 새로고침 후 확인하세요.',
            'Trạng thái đã đổi hoặc còn thiếu yêu cầu. Hãy tải lại.',
            'State changed or requirements remain. Refresh and check.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _closureLabel(String key) => switch (key) {
    'orders' || 'leftover_packaging' || 'prepaid_handoffs' || 'kds_handoffs' =>
      _text('미완료 주문 · 점장', 'Đơn chưa xong · quản lý', 'Open orders · manager'),
    'occupied_tables' => _text(
      '사용 중 테이블 · 홀 담당',
      'Bàn đang dùng · phục vụ',
      'Occupied tables · service staff',
    ),
    'direct_requests' => _text(
      '대기 직접 주문 · 점장',
      'Đơn trực tiếp chờ · quản lý',
      'Pending direct orders · manager',
    ),
    'account_jobs' => _text(
      '계정 발급 작업 · 관리자',
      'Tạo tài khoản · quản trị',
      'Account provisioning · administrator',
    ),
    'purchase_requests' => _text(
      '미완료 구매 요청 · 발주 담당',
      'Yêu cầu mua chưa xong · người yêu cầu',
      'Open requests · requester',
    ),
    'purchase_orders' => _text(
      '미완료 발주 · 구매 담당',
      'PO chưa xong · mua hàng',
      'Open purchase orders · buyer',
    ),
    'draft_receipts' => _text(
      '미확정 검수 · PR 담당',
      'Kiểm nhận chưa chốt · PR',
      'Draft inspections · PR receiver',
    ),
    'held_lots' => _text(
      '보류·불합격 재고 · PR 담당',
      'Hàng tạm giữ/không đạt · PR',
      'Held/rejected stock · PR receiver',
    ),
    'accounting' => _text(
      '대사·미지급 · Office 회계',
      'Đối soát/chưa trả · kế toán Office',
      'Reconciliation/unpaid · Office accounting',
    ),
    'supplier_reports' => _text(
      '공급업체 미전송 문서 · PR 담당',
      'Chứng từ chưa gửi NCC · PR',
      'Unsent supplier documents · PR receiver',
    ),
    'print_retries' => _text(
      '출력 재시도 · 점장',
      'In lại · quản lý',
      'Print retries · manager',
    ),
    'invoice_retries' || 'misa_retries' => _text(
      '송장 오류·재시도 · 법인 회계',
      'Lỗi/thử lại hóa đơn · kế toán',
      'Invoice errors/retries · entity accounting',
    ),
    _ => _text(
      '장치 미전송 작업 · 현장 담당',
      'Tác vụ thiết bị chưa gửi · nhân viên',
      'Unsent device work · on-site staff',
    ),
  };

  Future<void> _transfer() async {
    setState(() => _busy = true);
    try {
      final options = await _service.transferOptions(widget.storeId);
      if (!mounted) return;
      final form = GlobalKey<FormState>();
      Map? target;
      final values = <String, String>{};
      final accepted = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(
            _text(
              '법인·브랜드 이전',
              'Chuyển pháp nhân/thương hiệu',
              'Transfer legal entity / brand',
            ),
          ),
          content: SizedBox(
            width: 600,
            child: SingleChildScrollView(
              child: Form(
                key: form,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      _text(
                        '미결 업무가 없는 폐점 상태에서만 이전합니다. 계정 ID와 과거 거래는 보존하며, 새 소속으로 재개점 확인이 필요합니다.',
                        'Chỉ chuyển khi đã đóng và không còn việc tồn. Giữ ID và giao dịch cũ; cần xác minh mở lại.',
                        'Transfer requires closure with no unfinished work. IDs and history are retained; reopening requires verification.',
                      ),
                    ),
                    DropdownButtonFormField<int>(
                      isExpanded: true,
                      decoration: InputDecoration(
                        labelText: _text(
                          '대상 법인·브랜드',
                          'Pháp nhân/thương hiệu đích',
                          'Destination entity / brand',
                        ),
                      ),
                      items: [
                        for (
                          var i = 0;
                          i < (options['targets'] as List).length;
                          i++
                        )
                          DropdownMenuItem(
                            value: i,
                            child: Text(
                              '${(options['targets'] as List)[i]['entity_name']} · ${(options['targets'] as List)[i]['brand_name']}',
                            ),
                          ),
                      ],
                      onChanged: (v) => target = v == null
                          ? null
                          : (options['targets'] as List)[v] as Map,
                      validator: (v) => v == null ? '*' : null,
                    ),
                    for (final entry in {
                      'reason': _text(
                        '이전 근거·사유',
                        'Căn cứ/lý do chuyển',
                        'Transfer evidence and reason',
                      ),
                      'scope_review': _text(
                        '권한 회수·새 담당자 확인 증거',
                        'Bằng chứng thu hồi quyền/bàn giao',
                        'Access revocation / new owner review evidence',
                      ),
                      'office_store_id': _text(
                        '확인된 Office 매장 UUID (구매 사용 매장)',
                        'UUID cửa hàng Office đã xác minh (có mua hàng)',
                        'Verified Office store UUID (purchasing stores)',
                      ),
                      'office_contract_version': _text(
                        'Office 계약 버전',
                        'Phiên bản hợp đồng Office',
                        'Office contract version',
                      ),
                      'office_evidence': _text(
                        'Office 매핑 확인 증거',
                        'Bằng chứng ánh xạ Office',
                        'Office mapping verification evidence',
                      ),
                    }.entries)
                      TextFormField(
                        decoration: InputDecoration(labelText: entry.value),
                        onChanged: (v) => values[entry.key] = v,
                        validator: (v) =>
                            ['reason', 'scope_review'].contains(entry.key) &&
                                (v ?? '').trim().length < 5
                            ? '*'
                            : null,
                      ),
                  ],
                ),
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(_text('취소', 'Hủy', 'Cancel')),
            ),
            FilledButton(
              onPressed: () {
                if (form.currentState!.validate()) Navigator.pop(context, true);
              },
              child: Text(
                _text(
                  '이전 기록·권한 회수',
                  'Ghi chuyển và thu hồi quyền',
                  'Record transfer and revoke access',
                ),
              ),
            ),
          ],
        ),
      );
      if (accepted != true || target == null || !mounted) return;
      await _service.write('admin_transfer_store_identity_v1', {
        'p_id': const Uuid().v4(),
        'p_store': widget.storeId,
        'p_expected_revision': (_data!['lifecycle'] as Map)['revision'],
        'p_brand': target!['brand_id'],
        'p_entity': target!['entity_id'],
        'p_evidence': values,
      });
      if (mounted) await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _text(
            '소속·브랜드 계정·Office 매핑·미결 업무를 확인하고 다시 조회하세요.',
            'Kiểm tra pháp nhân, tài khoản thương hiệu, Office và việc tồn rồi tải lại.',
            'Review destination scope, brand accounts, Office mapping and pending work, then refresh.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _operationalAcceptance() async {
    setState(() => _busy = true);
    try {
      final inputs = await _service.operationalInputs(widget.storeId);
      if (!mounted) return;
      final payload = await showStoreOperationalAcceptance(
        context,
        inputs: inputs,
        employees: (_data?['employees'] as List? ?? []).cast<Map>(),
      );
      if (payload == null || !mounted) return;
      final employee = payload.remove('employee_id');
      await _service.write('admin_record_store_operational_acceptance_v1', {
        'p_id': const Uuid().v4(),
        'p_store': widget.storeId,
        'p_employee': employee,
        'p_source_hash': inputs['source_hash'],
        'p_payload': payload,
      });
      if (mounted) await _load();
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _text(
            '운영 기준·직원·Office 연결을 확인하고 다시 조회하세요.',
            'Kiểm tra tiêu chuẩn, nhân viên và liên kết Office rồi tải lại.',
            'Review operating criteria, employee and Office connection, then refresh.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final checks = (_data?['checks'] as Map?) ?? {};
    final state = (_data?['lifecycle'] as Map?)?['state'];
    final names = {
      'operational_acceptance': _text(
        '채널·결제·시재·장애 복구·Office 인수',
        'Bàn giao kênh, thanh toán, tiền mặt, khôi phục và Office',
        'Channel, payment, cash, recovery and Office acceptance',
      ),
      'initial_inventory': _text(
        '초기 재고 실사',
        'Kiểm kê tồn đầu kỳ',
        'Opening inventory count',
      ),
      'recipes': _text(
        '메뉴 레시피·재고 연결 또는 비대상 근거',
        'Công thức, liên kết tồn hoặc lý do không áp dụng',
        'Recipes, inventory links or explicit exemptions',
      ),
      'identity': _text(
        '매장·브랜드·법인 연결',
        'Liên kết cửa hàng, thương hiệu, pháp nhân',
        'Store, brand and legal entity',
      ),
      'accounts': _text(
        '계정·권한·초기 비밀번호 변경',
        'Tài khoản, quyền và đổi mật khẩu ban đầu',
        'Accounts, access and initial password change',
      ),
      'credential_handover': _text(
        '현재 계정 인수 기록',
        'Bàn giao tài khoản hiện tại',
        'Current credential handover',
      ),
      'employees': _text(
        '활성 직원',
        'Nhân viên đang hoạt động',
        'Active employees',
      ),
      'opening_tests': _text(
        '출력 설정과 테스트',
        'Cấu hình và kiểm tra in',
        'Printer configuration and tests',
      ),
      'service_areas': _text(
        '구역·테이블·인계 담당',
        'Khu vực, bàn và người nhận',
        'Areas, tables and handoff recipients',
      ),
      'kitchens': _text('주방 담당', 'Người phụ trách bếp', 'Kitchen assignments'),
      'workflow': _text(
        '다중 주방 게시·전환',
        'Phát hành và kích hoạt nhiều bếp',
        'Multi-kitchen publication and activation',
      ),
      'menus': _text('판매 메뉴', 'Thực đơn bán', 'Sellable menus'),
      'field_verification': _text(
        '실제 출력·조리·인계 확인',
        'Xác nhận in, nấu và bàn giao thực tế',
        'Physical output, cooking and handoff verification',
      ),
      'invoice_mapping': _text(
        '신고용 메뉴 매핑',
        'Ánh xạ món cho báo cáo',
        'Invoice menu mapping',
      ),
    };
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              _text(
                '영업 준비 및 개점',
                'Sẵn sàng và mở cửa',
                'Readiness and opening',
              ),
              style: Theme.of(context).textTheme.titleMedium,
            ),
            if (state != null)
              Text(switch (state) {
                'preparing' => _text('개점 준비 중', 'Đang chuẩn bị', 'Preparing'),
                'active' => _text('영업 중', 'Đang hoạt động', 'Active'),
                'suspended' => _text(
                  '신규 주문 중지',
                  'Tạm dừng đơn mới',
                  'New orders suspended',
                ),
                _ => _text('폐점', 'Đã đóng', 'Closed'),
              }),
            for (final check in checks.entries)
              ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  check.value == true
                      ? Icons.check_circle_outline
                      : Icons.pending_outlined,
                ),
                title: Text(names[check.key] ?? check.key.toString()),
              ),
            Text(
              _text(
                '발주 준비는 영업 개점과 별도로 관리합니다.',
                'Sẵn sàng mua hàng được quản lý riêng.',
                'Procurement readiness is managed separately.',
              ),
            ),
            if (_data?['closure'] is Map)
              ExpansionTile(
                title: Text(
                  _text(
                    '폐점 전 미결 업무',
                    'Công việc còn lại trước đóng cửa',
                    'Pending work before closure',
                  ),
                ),
                children: [
                  for (final entry in (_data!['closure'] as Map).entries)
                    if (entry.value != 0)
                      ListTile(
                        title: Text(_closureLabel(entry.key.toString())),
                        trailing: Text(entry.value.toString()),
                      ),
                ],
              ),
            if (_error != null)
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            Wrap(
              spacing: 8,
              children: [
                TextButton(
                  onPressed: _busy ? null : _load,
                  child: Text(_text('새로고침', 'Tải lại', 'Refresh')),
                ),
                OutlinedButton(
                  onPressed: _busy ? null : _operationalAcceptance,
                  child: Text(
                    _text(
                      '개점 운영 기준 확인',
                      'Xác nhận tiêu chuẩn vận hành',
                      'Confirm opening operating criteria',
                    ),
                  ),
                ),
                OutlinedButton(
                  onPressed:
                      _busy ||
                          checks['accounts'] != true ||
                          checks['employees'] != true
                      ? null
                      : () => _action('handover'),
                  child: Text(
                    _text(
                      '계정 인수 기록',
                      'Bàn giao tài khoản',
                      'Record account handover',
                    ),
                  ),
                ),
                OutlinedButton(
                  key: const Key('store_record_verification'),
                  onPressed:
                      _busy ||
                          checks.isEmpty ||
                          checks.entries.any(
                            (e) =>
                                e.key != 'field_verification' &&
                                e.value != true,
                          )
                      ? null
                      : () => _action('verification'),
                  child: Text(
                    _text(
                      '현장 확인 기록',
                      'Ghi nhận kiểm tra thực tế',
                      'Record field verification',
                    ),
                  ),
                ),
                FilledButton(
                  key: const Key('store_open_for_business'),
                  onPressed:
                      _busy ||
                          _data?['business_ready'] != true ||
                          state == 'active' ||
                          state == 'closed'
                      ? null
                      : () => _action('active'),
                  child: Text(_text('영업 시작', 'Mở cửa', 'Open for business')),
                ),
                if (state == 'closed')
                  OutlinedButton(
                    onPressed: _busy ? null : _transfer,
                    child: Text(
                      _text(
                        '법인·브랜드 이전',
                        'Chuyển pháp nhân/thương hiệu',
                        'Transfer entity / brand',
                      ),
                    ),
                  ),
                if (state == 'closed')
                  OutlinedButton(
                    onPressed: _busy ? null : () => _action('reopen'),
                    child: Text(
                      _text(
                        '같은 매장으로 재개점 준비',
                        'Chuẩn bị mở lại cùng cửa hàng',
                        'Prepare this store for reopening',
                      ),
                    ),
                  ),
                if (state != 'closed' && _data?['closure'] is Map)
                  OutlinedButton(
                    onPressed:
                        _busy ||
                            (_data!['closure'] as Map).values.any((v) => v != 0)
                        ? null
                        : () => _action('closed'),
                    child: Text(
                      _text(
                        '미결 업무 정리 후 폐점',
                        'Đóng cửa sau khi hoàn tất công việc',
                        'Close after settling pending work',
                      ),
                    ),
                  ),
                if (state == 'active')
                  OutlinedButton(
                    onPressed: _busy ? null : () => _action('suspended'),
                    child: Text(
                      _text(
                        '신규 주문 중지',
                        'Tạm dừng đơn mới',
                        'Suspend new orders',
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
}
