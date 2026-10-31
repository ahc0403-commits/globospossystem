import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/pos_backend.dart';

Future<Map<String, dynamic>?> showLegalEntityEditor(BuildContext context) =>
    showDialog<Map<String, dynamic>>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const _LegalEntityEditor(),
    );

class _LegalEntityEditor extends StatefulWidget {
  const _LegalEntityEditor();
  @override
  State<_LegalEntityEditor> createState() => _LegalEntityEditorState();
}

class _LegalEntityEditorState extends State<_LegalEntityEditor> {
  // Stable across retry, including a lost acknowledgement after commit.
  final _id = const Uuid().v4();
  final _name = TextEditingController();
  final _taxCode = TextEditingController();
  String _owner = 'internal';
  bool _busy = false;
  bool _failed = false;
  String tr(String ko, String en, String vi) =>
      switch (Localizations.localeOf(context).languageCode) {
        'ko' => ko,
        'vi' => vi,
        _ => en,
      };

  Future<void> _save() async {
    if (_busy || _name.text.trim().isEmpty || _taxCode.text.trim().isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final result = await supabase.rpc(
        'admin_upsert_tax_entity_v2',
        params: {
          'p_tax_entity_id': _id,
          'p_tax_code': _taxCode.text.trim(),
          'p_name': _name.text.trim(),
          'p_owner_type': _owner,
          'p_onboarding_status': 'ready',
        },
      );
      if (mounted) {
        Navigator.pop(context, Map<String, dynamic>.from(result as Map));
      }
    } catch (_) {
      if (mounted) setState(() => _failed = true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _taxCode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(tr('법인 등록', 'Register legal entity', 'Đăng ký pháp nhân')),
    content: SizedBox(
      width: 480,
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: tr('법인명', 'Legal name', 'Tên pháp nhân'),
              ),
            ),
            TextField(
              controller: _taxCode,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: tr('세금번호', 'Tax code', 'Mã số thuế'),
              ),
            ),
            DropdownButtonFormField<String>(
              initialValue: _owner,
              decoration: InputDecoration(
                labelText: tr('소유 유형', 'Ownership', 'Loại sở hữu'),
              ),
              items: [
                DropdownMenuItem(
                  value: 'internal',
                  child: Text(tr('내부 법인', 'Internal', 'Nội bộ')),
                ),
                DropdownMenuItem(
                  value: 'external',
                  child: Text(tr('외부 법인', 'External', 'Bên ngoài')),
                ),
              ],
              onChanged: _busy ? null : (v) => setState(() => _owner = v!),
            ),
            if (_failed)
              Text(
                tr(
                  '등록하지 못했습니다. 세금번호와 권한을 확인하고 다시 시도하세요.',
                  'Registration failed. Check the tax code and your access, then retry.',
                  'Đăng ký thất bại. Kiểm tra mã số thuế và quyền truy cập rồi thử lại.',
                ),
              ),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: Text(tr('취소', 'Cancel', 'Hủy')),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: Text(tr('등록', 'Register', 'Đăng ký')),
      ),
    ],
  );
}
