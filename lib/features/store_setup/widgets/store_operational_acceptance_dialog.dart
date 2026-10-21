import 'package:flutter/material.dart';

Future<Map<String, dynamic>?> showStoreOperationalAcceptance(
  BuildContext context, {
  required Map<String, dynamic> inputs,
  required List<Map> employees,
}) {
  String t(String ko, String en, String vi) =>
      switch (Localizations.localeOf(context).languageCode) {
        'ko' => ko,
        'vi' => vi,
        _ => en,
      };
  final form = GlobalKey<FormState>();
  final checks = <String, bool>{};
  final exemptions = <String, String>{};
  final menus = (inputs['menus_without_recipe'] as List? ?? []).cast<Map>();
  final values = <String, dynamic>{
    'office_store_id': inputs['office_store_id'],
  };
  var page = 0;
  String? error;
  return showDialog<Map<String, dynamic>>(
    context: context,
    barrierDismissible: false,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(
          t(
            '개점 운영 기준 확인',
            'Confirm opening operating criteria',
            'Xác nhận tiêu chuẩn vận hành khai trương',
          ),
        ),
        content: SizedBox(
          width: 680,
          child: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    t(
                      '베트남 · VND · 호찌민 시간. 실제 확인한 값과 증거를 기록합니다.',
                      'Vietnam · VND · Ho Chi Minh time. Record observed values and evidence.',
                      'Việt Nam · VND · giờ Hồ Chí Minh. Ghi giá trị và bằng chứng thực tế.',
                    ),
                  ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  DropdownButtonFormField<String>(
                    isExpanded: true,
                    decoration: InputDecoration(
                      labelText: t(
                        '운영 인수 직원',
                        'Employee receiving operations',
                        'Nhân viên nhận bàn giao',
                      ),
                    ),
                    items: [
                      for (final e in employees)
                        DropdownMenuItem(
                          value: e['id'].toString(),
                          child: Text(e['name'].toString()),
                        ),
                    ],
                    onChanged: (v) => values['employee_id'] = v,
                    validator: (v) => v == null ? '*' : null,
                  ),
                  TextFormField(
                    decoration: InputDecoration(
                      labelText: t(
                        '개점 시재 실사 금액 (0도 명시 입력)',
                        'Counted opening cash (enter zero explicitly)',
                        'Tiền đầu kỳ đã kiểm đếm (nhập rõ số 0)',
                      ),
                    ),
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
                    onChanged: (v) =>
                        values['opening_cash_amount'] = num.tryParse(v),
                    validator: (v) {
                      final n = num.tryParse(v ?? '');
                      return n != null && n.isFinite && n >= 0 ? null : '*';
                    },
                  ),
                  TextFormField(
                    decoration: InputDecoration(
                      labelText: t(
                        '운영·시재 확인 증거',
                        'Operating / cash evidence',
                        'Bằng chứng vận hành / tiền mặt',
                      ),
                    ),
                    maxLength: 1000,
                    onChanged: (v) => values['evidence_reference'] = v.trim(),
                    validator: (v) => (v?.trim().length ?? 0) >= 5 ? null : '*',
                  ),
                  for (final c in {
                    'channels': t(
                      '사용 채널·영업시간·취소 권한 확인',
                      'Channels, ordering hours and cancellation roles checked',
                      'Đã kiểm tra kênh, giờ nhận đơn và quyền hủy',
                    ),
                    'payments_refunds': t(
                      '결제 수단·수금계좌·환불 권한 확인',
                      'Payment methods, receiving accounts and refund roles checked',
                      'Đã kiểm tra thanh toán, tài khoản nhận và quyền hoàn tiền',
                    ),
                    'cash_closing': t(
                      '시재·현금 마감 절차 확인',
                      'Opening cash and daily cash closing checked',
                      'Đã kiểm tra tiền đầu kỳ và chốt tiền',
                    ),
                    'offline_recovery': t(
                      '오프라인·재전송·장애 복구 확인',
                      'Offline, retries and recovery checked',
                      'Đã kiểm tra ngoại tuyến, gửi lại và khôi phục',
                    ),
                    'device_handover': t(
                      '실제 장치·담당자 인수 확인',
                      'Actual devices and responsible staff checked',
                      'Đã kiểm tra thiết bị và người phụ trách',
                    ),
                    'reporting_owner': t(
                      '매장 신고 구분·대표 확인 책임 확인',
                      'Store reporting and owner confirmation responsibility checked',
                      'Đã kiểm tra báo cáo cửa hàng và trách nhiệm xác nhận',
                    ),
                  }.entries)
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(c.value),
                      value: checks[c.key] ?? false,
                      onChanged: (v) => update(() => checks[c.key] = v == true),
                    ),
                  if (inputs['office_required'] == true) ...[
                    Text(
                      t(
                        'Office에서 확인한 매장 ID·계약 버전·검증 문서 참조를 입력하세요.',
                        'Enter the store ID, contract version and evidence verified in Office.',
                        'Nhập ID cửa hàng, phiên bản hợp đồng và bằng chứng đã kiểm tra trong Office.',
                      ),
                    ),
                    for (final c in {
                      'office_store_id': t(
                        'Office 매장 UUID',
                        'Office store UUID',
                        'UUID cửa hàng Office',
                      ),
                      'office_contract_version': t(
                        '확인한 계약 버전',
                        'Verified contract version',
                        'Phiên bản đã kiểm tra',
                      ),
                      'office_evidence': t(
                        '매장·법인·발주·입고 대사 증거',
                        'Store, entity, PO and receipt reconciliation evidence',
                        'Bằng chứng đối soát cửa hàng, pháp nhân, PO và nhập hàng',
                      ),
                    }.entries)
                      TextFormField(
                        initialValue: values[c.key]?.toString(),
                        decoration: InputDecoration(labelText: c.value),
                        maxLength: 500,
                        onChanged: (v) => values[c.key] = v.trim(),
                        validator: (v) =>
                            (v?.trim().length ?? 0) >=
                                (c.key == 'office_store_id'
                                    ? 36
                                    : c.key == 'office_evidence'
                                    ? 5
                                    : 1)
                            ? null
                            : '*',
                      ),
                  ],
                  if (menus.isNotEmpty) ...[
                    Text(
                      t(
                        '아래 메뉴는 레시피가 없습니다. 레시피를 등록하거나 재고 소모가 없는 이유를 명시하세요.',
                        'These menus have no recipe. Register recipes or explain why stock consumption does not apply.',
                        'Các món dưới chưa có công thức. Đăng ký công thức hoặc ghi lý do không tiêu hao tồn kho.',
                      ),
                    ),
                    for (final menu in menus.skip(page * 10).take(10))
                      TextFormField(
                        key: ValueKey(menu['id']),
                        initialValue: exemptions[menu['id']],
                        decoration: InputDecoration(
                          labelText:
                              '${menu['name']} · ${t('비대상 사유', 'Exemption reason', 'Lý do không áp dụng')}',
                        ),
                        maxLength: 500,
                        onChanged: (v) =>
                            exemptions[menu['id'].toString()] = v.trim(),
                      ),
                    Row(
                      children: [
                        Text('${page + 1} / ${(menus.length / 10).ceil()}'),
                        if (page > 0)
                          TextButton(
                            onPressed: () => update(() => page--),
                            child: Text(t('이전', 'Previous', 'Trước')),
                          ),
                        if ((page + 1) * 10 < menus.length)
                          TextButton(
                            onPressed: () => update(() => page++),
                            child: Text(t('다음', 'Next', 'Tiếp')),
                          ),
                      ],
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
              if (!form.currentState!.validate()) return;
              if (checks.length != 6 ||
                  checks.values.any((v) => !v) ||
                  menus.any((m) => (exemptions[m['id']]?.length ?? 0) < 5)) {
                update(
                  () => error = t(
                    '확인 항목과 모든 레시피 비대상 사유를 작성하세요.',
                    'Complete the checks and every recipe exemption.',
                    'Hoàn thành các mục và lý do không áp dụng công thức.',
                  ),
                );
                return;
              }
              Navigator.pop(context, {
                ...values,
                'checks': checks,
                'currency': 'VND',
                'timezone': 'Asia/Ho_Chi_Minh',
                'recipe_exemptions': [
                  for (final e in exemptions.entries)
                    {'menu_id': e.key, 'reason': e.value},
                ],
              });
            },
            child: Text(
              t(
                '확인한 기준 기록',
                'Record verified criteria',
                'Ghi tiêu chuẩn đã kiểm tra',
              ),
            ),
          ),
        ],
      ),
    ),
  );
}
