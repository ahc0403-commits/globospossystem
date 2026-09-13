import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';

class ProcurementInspectionDialog extends StatefulWidget {
  const ProcurementInspectionDialog({
    super.key,
    required this.lines,
    required this.payload,
    required this.uploadPhoto,
  });
  final List<Map<String, dynamic>> lines, payload;
  final Future<String> Function(XFile file) uploadPhoto;
  @override
  State<ProcurementInspectionDialog> createState() =>
      _ProcurementInspectionDialogState();
}

class _ProcurementInspectionDialogState
    extends State<ProcurementInspectionDialog> {
  final _form = GlobalKey<FormState>();
  late final List<Map<String, dynamic>> _rows;
  bool _uploading = false;
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
    _rows = widget.payload
        .map(
          (l) => {
            ...l,
            'inspection': <String, dynamic>{
              'spec_ok': false,
              'quality_ok': false,
              'packaging_ok': false,
              'expiry_not_applicable': false,
              'temperature_ok': false,
              'issue_type': 'none',
              'photo_paths': <String>[],
            },
            'rejected_quantity_base': '0',
          },
        )
        .toList();
  }

  String issue(String code) => switch (code) {
    'none' => t('이상 없음', 'No issue', 'Không có vấn đề'),
    'shortage' => t('수량 부족', 'Shortage', 'Thiếu hàng'),
    'excess' => t('초과 납품', 'Excess', 'Giao thừa'),
    'wrong_item' => t('다른 품목', 'Wrong item', 'Sai mặt hàng'),
    'damaged' => t('파손·불량', 'Damage', 'Hư hỏng'),
    'specification' => t('규격 불일치', 'Wrong specification', 'Sai quy cách'),
    'quality' => t('품질 불량', 'Quality', 'Chất lượng'),
    'expiry' => t('유통기한', 'Expiry', 'Hạn dùng'),
    _ => t('온도', 'Temperature', 'Nhiệt độ'),
  };
  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(t('입고 검수', 'Delivery inspection', 'Kiểm tra nhập hàng')),
    content: SizedBox(
      width: 720,
      child: SingleChildScrollView(
        child: Form(
          key: _form,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_error != null) Text(_error!),
              for (final row in _rows)
                Builder(
                  builder: (context) {
                    final line = widget.lines.firstWhere(
                      (l) => l['id'] == row['purchase_order_line_id'],
                    );
                    final q = row['inspection'] as Map<String, dynamic>;
                    return Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: [
                            Text(
                              '${(line['product'] as Map?)?['name'] ?? line['product_name']} · ${t('입고 기준단위 수량', 'Received base quantity', 'Số lượng nhận cơ sở')}: ${row['received_quantity_base']}',
                            ),
                            for (final check in {
                              'spec_ok': t(
                                '품목·단위·규격 확인',
                                'Item, unit and specification checked',
                                'Đã kiểm tra mặt hàng, đơn vị, quy cách',
                              ),
                              'quality_ok': t(
                                '품질 적합',
                                'Quality acceptable',
                                'Chất lượng đạt',
                              ),
                              'packaging_ok': t(
                                '포장 상태 적합',
                                'Packaging acceptable',
                                'Bao bì đạt',
                              ),
                              'expiry_not_applicable': t(
                                '유통기한 관리 대상 아님',
                                'Expiry not applicable',
                                'Không áp dụng hạn dùng',
                              ),
                              'temperature_ok': t(
                                '냉장·냉동 온도 기준 적합',
                                'Cold-chain temperature acceptable',
                                'Nhiệt độ bảo quản đạt',
                              ),
                            }.entries)
                              CheckboxListTile(
                                value: q[check.key] == true,
                                title: Text(check.value),
                                onChanged: (v) =>
                                    setState(() => q[check.key] = v),
                              ),
                            TextFormField(
                              decoration: InputDecoration(
                                labelText: t(
                                  '유통기한 (YYYY-MM-DD)',
                                  'Expiry (YYYY-MM-DD)',
                                  'Hạn dùng (YYYY-MM-DD)',
                                ),
                              ),
                              onChanged: (v) => q['expiry_date'] = v,
                              validator: (v) {
                                if (q['expiry_not_applicable'] == true ||
                                    double.tryParse(
                                          row['rejected_quantity_base']
                                              .toString(),
                                        ) ==
                                        row['received_quantity_base']) {
                                  return null;
                                }
                                return v != null &&
                                        RegExp(
                                          r'^\d{4}-\d{2}-\d{2}$',
                                        ).hasMatch(v) &&
                                        DateTime.tryParse(v)
                                                ?.toIso8601String()
                                                .substring(0, 10) ==
                                            v
                                    ? null
                                    : t(
                                        '유통기한 확인',
                                        'Check expiry',
                                        'Kiểm tra hạn dùng',
                                      );
                              },
                            ),
                            TextFormField(
                              decoration: InputDecoration(
                                labelText: t(
                                  '냉장·냉동 품목 실측 온도 °C',
                                  'Measured cold-chain temperature °C',
                                  'Nhiệt độ đo thực tế °C',
                                ),
                              ),
                              onChanged: (v) => q['temperature_c'] = v,
                              validator: (v) =>
                                  v == null ||
                                      v.trim().isEmpty ||
                                      (double.tryParse(v)?.isFinite ?? false)
                                  ? null
                                  : '°C',
                            ),
                            DropdownButtonFormField<String>(
                              initialValue: 'none',
                              decoration: InputDecoration(
                                labelText: t(
                                  '차이·이상 유형',
                                  'Issue type',
                                  'Loại vấn đề',
                                ),
                              ),
                              items:
                                  [
                                        'none',
                                        'shortage',
                                        'excess',
                                        'wrong_item',
                                        'damaged',
                                        'specification',
                                        'quality',
                                        'expiry',
                                        'temperature',
                                      ]
                                      .map(
                                        (i) => DropdownMenuItem(
                                          value: i,
                                          child: Text(issue(i)),
                                        ),
                                      )
                                      .toList(),
                              onChanged: (v) =>
                                  setState(() => q['issue_type'] = v),
                            ),
                            TextFormField(
                              initialValue: '0',
                              decoration: InputDecoration(
                                labelText: t(
                                  '불합격 수량 (기준 단위)',
                                  'Rejected quantity (base units)',
                                  'Số lượng loại (đơn vị cơ sở)',
                                ),
                              ),
                              onChanged: (v) =>
                                  row['rejected_quantity_base'] = v,
                              validator: (v) {
                                final n = double.tryParse(v ?? '');
                                return n != null &&
                                        n.isFinite &&
                                        n >= 0 &&
                                        n <=
                                            (row['received_quantity_base']
                                                as num)
                                    ? null
                                    : t(
                                        '수량 확인',
                                        'Check quantity',
                                        'Kiểm tra số lượng',
                                      );
                              },
                            ),
                            TextFormField(
                              decoration: InputDecoration(
                                labelText: t(
                                  '차이·불량 사유',
                                  'Issue reason',
                                  'Lý do vấn đề',
                                ),
                              ),
                              onChanged: (v) => row['discrepancy_reason'] = v,
                              validator: (v) =>
                                  q['issue_type'] != 'none' &&
                                      (v == null || v.trim().isEmpty)
                                  ? '*'
                                  : null,
                            ),
                            TextButton.icon(
                              onPressed: _uploading
                                  ? null
                                  : () async {
                                      final file = await openFile(
                                        acceptedTypeGroups: [
                                          const XTypeGroup(
                                            label: 'Photos',
                                            extensions: ['jpg', 'jpeg', 'png'],
                                          ),
                                        ],
                                      );
                                      if (file == null || !mounted) return;
                                      setState(() => _uploading = true);
                                      try {
                                        final path = await widget.uploadPhoto(
                                          file,
                                        );
                                        if (mounted) {
                                          setState(
                                            () => (q['photo_paths'] as List)
                                                .add(path),
                                          );
                                        }
                                      } catch (_) {
                                        if (mounted) {
                                          setState(
                                            () => _error = t(
                                              '사진 업로드 실패',
                                              'Photo upload failed',
                                              'Tải ảnh thất bại',
                                            ),
                                          );
                                        }
                                      } finally {
                                        if (mounted) {
                                          setState(() => _uploading = false);
                                        }
                                      }
                                    },
                              icon: const Icon(Icons.add_a_photo_outlined),
                              label: Text(
                                '${t('사진 첨부', 'Attach photo', 'Đính kèm ảnh')} (${(q['photo_paths'] as List).length})',
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
            ],
          ),
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _uploading ? null : () => Navigator.pop(context),
        child: Text(MaterialLocalizations.of(context).cancelButtonLabel),
      ),
      FilledButton(
        onPressed: _uploading
            ? null
            : () {
                if (_form.currentState!.validate()) {
                  Navigator.pop(context, _rows);
                }
              },
        child: Text(t('검수 저장', 'Save inspection', 'Lưu kiểm tra')),
      ),
    ],
  );
}
