import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

Future<void> editQualityProfile(
  BuildContext context, {
  required String storeId,
  required Map product,
  required Future<void> Function(String, Map<String, dynamic>) save,
}) async {
  String t(String ko, String vi, String en) =>
      switch (Localizations.localeOf(context).languageCode) {
        'ko' => ko,
        'vi' => vi,
        _ => en,
      };
  final existing = product['quality'] as Map?;
  final criteria = Map<String, dynamic>.from(
    existing?['criteria'] as Map? ?? {},
  );
  var reason = '';
  final form = GlobalKey<FormState>();
  final accepted = await showDialog<bool>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        title: Text(
          t(
            '품목별 품질 기준 승인',
            'Phê duyệt tiêu chí chất lượng',
            'Approve item quality criteria',
          ),
        ),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: Form(
              key: form,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('${product['product_code']} · ${product['name']}'),
                  Text(
                    t(
                      '실제 품목 자료와 책임자 기준을 입력하십시오. 새 버전은 이후 발주에 적용되며, 기존 발주를 바꾸려면 별도 변경·재검수가 필요합니다.',
                      'Nhập tiêu chí từ tài liệu thực tế và người chịu trách nhiệm. Phiên bản mới áp dụng cho đơn sau; đơn đã phát hành cần sửa đổi và kiểm lại riêng.',
                      'Enter verified item criteria. New versions apply to future orders; issued orders require a separate amendment and reinspection.',
                    ),
                  ),
                  for (final field in {
                    'temperature_required': t(
                      '온도 관리 대상',
                      'Yêu cầu kiểm tra nhiệt độ',
                      'Temperature controlled',
                    ),
                    'expiry_required': t(
                      '유통기한 관리 대상',
                      'Yêu cầu hạn dùng',
                      'Expiry controlled',
                    ),
                    'photo_required': t(
                      '검수 사진 필수',
                      'Bắt buộc ảnh kiểm tra',
                      'Inspection photo required',
                    ),
                    'lot_required': t(
                      '로트 추적 대상',
                      'Yêu cầu theo dõi lô',
                      'Lot tracking required',
                    ),
                  }.entries)
                    DropdownButtonFormField<bool>(
                      initialValue: criteria[field.key] as bool?,
                      decoration: InputDecoration(labelText: field.value),
                      items: [
                        DropdownMenuItem(
                          value: true,
                          child: Text(t('대상', 'Có', 'Required')),
                        ),
                        DropdownMenuItem(
                          value: false,
                          child: Text(t('비대상', 'Không', 'Not applicable')),
                        ),
                      ],
                      onChanged: (v) => update(() => criteria[field.key] = v),
                      validator: (v) => v == null
                          ? t(
                              '명시적으로 선택하십시오.',
                              'Vui lòng chọn.',
                              'Select explicitly.',
                            )
                          : null,
                    ),
                  for (final field in {
                    if (criteria['temperature_required'] == true) ...{
                      'temperature_min_c': t(
                        '최저 온도 °C',
                        'Nhiệt độ tối thiểu °C',
                        'Minimum temperature °C',
                      ),
                      'temperature_max_c': t(
                        '최고 온도 °C',
                        'Nhiệt độ tối đa °C',
                        'Maximum temperature °C',
                      ),
                    },
                    if (criteria['expiry_required'] == true)
                      'min_remaining_days': t(
                        '최소 잔여 유통기한 (일)',
                        'Số ngày hạn dùng còn lại tối thiểu',
                        'Minimum remaining shelf life (days)',
                      ),
                    'min_sample_count': t(
                      '최소 검사 표본 수',
                      'Số mẫu kiểm tra tối thiểu',
                      'Minimum sample count',
                    ),
                  }.entries)
                    TextFormField(
                      key: ValueKey(field.key),
                      initialValue: criteria[field.key]?.toString(),
                      decoration: InputDecoration(labelText: field.value),
                      keyboardType: const TextInputType.numberWithOptions(
                        decimal: true,
                        signed: true,
                      ),
                      onChanged: (v) => criteria[field.key] = num.tryParse(v),
                      validator: (v) {
                        final n = num.tryParse(v ?? '');
                        if (n == null || !n.isFinite) {
                          return t(
                            '수치가 필요합니다.',
                            'Cần nhập số.',
                            'Enter a number.',
                          );
                        }
                        if (field.key == 'min_sample_count' &&
                            (n < 1 || n > 1000 || n != n.round())) {
                          return '1–1000';
                        }
                        if (field.key == 'min_remaining_days' &&
                            (n < 0 || n > 3650 || n != n.round())) {
                          return '0–3650';
                        }
                        if (field.key.startsWith('temperature_') &&
                            (n < -100 || n > 100)) {
                          return '−100–100 °C';
                        }
                        if (field.key == 'temperature_max_c' &&
                            criteria['temperature_min_c'] is num &&
                            n < (criteria['temperature_min_c'] as num)) {
                          return t(
                            '최저 온도 이상이어야 합니다.',
                            'Phải lớn hơn hoặc bằng nhiệt độ tối thiểu.',
                            'Must be at least the minimum.',
                          );
                        }
                        return null;
                      },
                    ),
                  TextFormField(
                    maxLength: 1000,
                    decoration: InputDecoration(
                      labelText: t(
                        '근거·승인 사유',
                        'Căn cứ/lý do phê duyệt',
                        'Evidence and approval reason',
                      ),
                    ),
                    onChanged: (v) => reason = v.trim(),
                    validator: (v) => (v ?? '').trim().length < 5
                        ? t(
                            '근거를 입력하십시오.',
                            'Nhập căn cứ.',
                            'Enter the evidence.',
                          )
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
            child: Text(t('취소', 'Hủy', 'Cancel')),
          ),
          FilledButton(
            onPressed: () {
              if (form.currentState!.validate()) Navigator.pop(context, true);
            },
            child: Text(
              t(
                '새 기준 버전 승인',
                'Phê duyệt phiên bản mới',
                'Approve new criteria version',
              ),
            ),
          ),
        ],
      ),
    ),
  );
  if (accepted != true) return;
  if (criteria['temperature_required'] != true) {
    criteria.remove('temperature_min_c');
    criteria.remove('temperature_max_c');
  }
  if (criteria['expiry_required'] != true) {
    criteria.remove('min_remaining_days');
  }
  await save('admin_publish_quality_profile_v1', {
    'p_id': const Uuid().v4(),
    'p_store': storeId,
    'p_product': product['id'],
    'p_expected_revision': existing?['revision'] ?? 0,
    'p_criteria': criteria,
    'p_reason': reason,
  });
}
