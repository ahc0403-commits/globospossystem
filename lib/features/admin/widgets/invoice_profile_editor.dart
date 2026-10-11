import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../../../main.dart';

/// Approval changes descriptions and units; monetary and VAT snapshots stay intact.
class InvoiceProfileEditor extends StatefulWidget {
  const InvoiceProfileEditor({
    super.key,
    required this.item,
    required this.onSaved,
  });
  final Map<String, dynamic> item;
  final VoidCallback onSaved;
  @override
  State<InvoiceProfileEditor> createState() => _InvoiceProfileEditorState();
}

class _InvoiceProfileEditorState extends State<InvoiceProfileEditor> {
  late final _name = TextEditingController(
    text: widget.item['invoice_name_vi']?.toString() ?? '',
  );
  late final _unit = TextEditingController(
    text: widget.item['invoice_unit_name']?.toString() ?? '',
  );
  DateTime? _effectiveDate, _effectiveTo;
  final _reference = TextEditingController(
    text: 'Menu management operator approval',
  );
  String? _approvedVersion;
  bool _saving = false;
  String? _error;
  String _copy(String ko, String vi, String en) =>
      switch (Localizations.localeOf(context).languageCode) {
        'vi' => vi,
        'en' => en,
        _ => ko,
      };
  @override
  void dispose() {
    _name.dispose();
    _unit.dispose();
    _reference.dispose();
    super.dispose();
  }

  Future<void> _approve() async {
    if (_name.text.trim().isEmpty ||
        _unit.text.trim().isEmpty ||
        _reference.text.trim().isEmpty) {
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final version = 'POS-menu-${const Uuid().v4()}';
      await supabase.rpc(
        'approve_menu_invoice_profile_v3',
        params: {
          'p_menu_item_id': widget.item['id'],
          'p_name': _name.text.trim(),
          'p_unit': _unit.text.trim(),
          'p_effective_from': _effectiveDate == null
              ? DateTime.now().toUtc().toIso8601String()
              : '${_effectiveDate!.toIso8601String().substring(0, 10)}T00:00:00+07:00',
          'p_effective_to': _effectiveTo == null
              ? null
              : '${_effectiveTo!.toIso8601String().substring(0, 10)}T00:00:00+07:00',
          'p_mapping_version': version,
          'p_source_reference': _reference.text.trim(),
        },
      );
      if (!mounted) return;
      setState(() => _approvedVersion = version);
      widget.onSaved();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            _copy(
              '계산서 명칭·단위를 승인했습니다.',
              'Đã duyệt tên và đơn vị hóa đơn.',
              'Invoice description and unit approved.',
            ),
          ),
        ),
      );
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = _copy(
            '승인하지 못했습니다. 적용일과 기존 승인 이력을 확인하세요.',
            'Không thể duyệt. Kiểm tra ngày áp dụng và lịch sử.',
            'Approval failed. Check the effective date and approval history.',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text(
        _copy(
          '계산서용 명칭·판매 단위',
          'Tên và đơn vị trên hóa đơn',
          'Invoice description and sales unit',
        ),
      ),
      TextField(
        key: const Key('invoice_profile_name'),
        controller: _name,
        maxLength: 200,
        decoration: InputDecoration(
          labelText: _copy(
            '승인할 베트남어 명칭',
            'Tên tiếng Việt cần duyệt',
            'Approved Vietnamese description',
          ),
        ),
      ),
      TextField(
        key: const Key('invoice_profile_unit'),
        controller: _unit,
        maxLength: 40,
        decoration: InputDecoration(
          labelText: _copy(
            '실제 판매 단위',
            'Đơn vị bán thực tế',
            'Actual sales unit',
          ),
        ),
      ),
      TextButton(
        onPressed: _saving
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
              ? _copy(
                  '적용 시점: 승인 시각',
                  'Áp dụng từ thời điểm duyệt',
                  'Effective from approval time',
                )
              : '${_copy('적용일', 'Ngày áp dụng', 'Effective date')}: ${_effectiveDate!.toIso8601String().substring(0, 10)}',
        ),
      ),
      TextField(
        controller: _reference,
        maxLength: 500,
        decoration: InputDecoration(
          labelText: _copy(
            '승인 근거·수정 이유',
            'Căn cứ phê duyệt',
            'Approval source / reason',
          ),
        ),
      ),
      TextButton(
        onPressed: _saving
            ? null
            : () async {
                final now = DateTime.now().toUtc().add(
                  const Duration(hours: 7),
                );
                final day = await showDatePicker(
                  context: context,
                  initialDate: _effectiveTo ?? now.add(const Duration(days: 1)),
                  firstDate: DateTime(2020),
                  lastDate: DateTime(now.year + 5),
                );
                if (day != null && mounted) setState(() => _effectiveTo = day);
              },
        child: Text(
          _effectiveTo == null
              ? _copy(
                  '종료일: 제한 없음',
                  'Ngày kết thúc: không giới hạn',
                  'Valid until: open ended',
                )
              : '${_copy('종료일 (미포함)', 'Ngày kết thúc (không gồm)', 'Valid until (exclusive)')}: ${_effectiveTo!.toIso8601String().substring(0, 10)}',
        ),
      ),
      if (_effectiveTo != null)
        TextButton(
          onPressed: _saving ? null : () => setState(() => _effectiveTo = null),
          child: Text(_copy('종료일 해제', 'Bỏ ngày kết thúc', 'Clear end date')),
        ),
      if (_approvedVersion != null)
        Text(
          '${_copy('승인 버전', 'Phiên bản phê duyệt', 'Approval version')}: $_approvedVersion',
        ),
      FilledButton(
        key: const Key('invoice_profile_approve'),
        onPressed: _saving ? null : _approve,
        child: Text(
          _copy(
            '계산서 명칭·단위 승인',
            'Duyệt tên và đơn vị',
            'Approve description and unit',
          ),
        ),
      ),
      if (_error != null)
        Text(
          _error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
    ],
  );
}
