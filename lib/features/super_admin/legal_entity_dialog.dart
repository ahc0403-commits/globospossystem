import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../../core/services/pos_backend.dart';
import '../../core/i18n/locale_extensions.dart';

typedef RegisterLegalEntity =
    Future<Map<String, dynamic>> Function(Map<String, dynamic> values);

Future<Map<String, dynamic>?> showLegalEntityEditor(
  BuildContext context, {
  RegisterLegalEntity? register,
}) => showDialog<Map<String, dynamic>>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _LegalEntityEditor(register: register),
);

class _LegalEntityEditor extends StatefulWidget {
  const _LegalEntityEditor({this.register});
  final RegisterLegalEntity? register;
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

  Future<void> _save() async {
    if (_busy || _name.text.trim().isEmpty || _taxCode.text.trim().isEmpty) {
      return;
    }
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final values = <String, dynamic>{
        'p_tax_entity_id': _id,
        'p_tax_code': _taxCode.text.trim(),
        'p_name': _name.text.trim(),
        'p_owner_type': _owner,
        'p_onboarding_status': 'ready',
      };
      final result = widget.register != null
          ? await widget.register!(values)
          : await supabase.rpc('admin_upsert_tax_entity_v2', params: values);
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
    title: Text(context.l10n.resilienceLegalEntityRegister),
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
                labelText: context.l10n.resilienceLegalEntityName,
              ),
            ),
            TextField(
              controller: _taxCode,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: context.l10n.resilienceLegalEntityTaxCode,
              ),
            ),
            DropdownButtonFormField<String>(
              initialValue: _owner,
              decoration: InputDecoration(
                labelText: context.l10n.resilienceLegalEntityOwnership,
              ),
              items: [
                DropdownMenuItem(
                  value: 'internal',
                  child: Text(context.l10n.resilienceLegalEntityInternal),
                ),
                DropdownMenuItem(
                  value: 'external',
                  child: Text(context.l10n.resilienceLegalEntityExternal),
                ),
              ],
              onChanged: _busy ? null : (v) => setState(() => _owner = v!),
            ),
            if (_failed) Text(context.l10n.resilienceLegalEntityFailed),
          ],
        ),
      ),
    ),
    actions: [
      TextButton(
        onPressed: _busy ? null : () => Navigator.pop(context),
        child: Text(context.l10n.cancel),
      ),
      FilledButton(
        onPressed: _busy ? null : _save,
        child: Text(context.l10n.resilienceLegalEntityRegister),
      ),
    ],
  );
}
