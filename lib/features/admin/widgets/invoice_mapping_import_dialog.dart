import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import '../../../core/services/pos_backend.dart';
import '../../restaurant_sales_export/invoice_mapping_service.dart';

class InvoiceMappingImportDialog extends StatefulWidget {
  const InvoiceMappingImportDialog({super.key, required this.taxEntityId});
  final String taxEntityId;
  @override
  State<InvoiceMappingImportDialog> createState() =>
      _InvoiceMappingImportDialogState();
}

class _InvoiceMappingImportDialogState
    extends State<InvoiceMappingImportDialog> {
  InvoiceMappingImport? _input;
  bool _saving = false;
  String? _message;
  String copy(String ko, String vi, String en) =>
      switch (Localizations.localeOf(context).languageCode) {
        'vi' => vi,
        'en' => en,
        _ => ko,
      };
  Future<void> _choose() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Invoice mapping JSON', extensions: ['json']),
      ],
    );
    if (file == null) return;
    try {
      if (await file.length() > 1000000) {
        throw const FormatException('INVOICE_MAPPING_FILE_TOO_LARGE');
      }
      final input = InvoiceMappingImport.parse(await file.readAsString());
      if (input.taxEntityId != widget.taxEntityId) {
        throw const FormatException('INVOICE_MAPPING_ENTITY_MISMATCH');
      }
      if (mounted) {
        setState(() {
          _input = input;
          _message = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _input = null;
          _message = '$e';
        });
      }
    }
  }

  Future<void> _approve() async {
    setState(() {
      _saving = true;
      _message = null;
    });
    try {
      final n = await InvoiceMappingService(
        (name, params) => supabase.rpc(name, params: params),
      ).approve(_input!, widget.taxEntityId);
      if (mounted) Navigator.of(context).pop(n);
    } catch (e) {
      if (mounted) setState(() => _message = '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(
      copy('계산서 매핑 일괄 승인', 'Duyệt ánh xạ hóa đơn', 'Approve invoice mappings'),
    ),
    content: SizedBox(
      width: 640,
      height: 420,
      child: Column(
        children: [
          Text(
            copy(
              '명칭·단위와 적용기간을 검토한 후 승인하세요. 기간은 파일에 기재된 범위로 저장됩니다.',
              'Kiểm tra tên, đơn vị và thời hạn. Giữ nguyên thời hạn trong file.',
              'Review descriptions, units and validity. The file’s exact validity is retained.',
            ),
          ),
          TextButton(
            onPressed: _saving ? null : _choose,
            child: Text(
              copy('매핑 JSON 선택', 'Chọn JSON ánh xạ', 'Choose mapping JSON'),
            ),
          ),
          if (_input case final input?)
            Expanded(
              child: ListView.builder(
                itemCount: input.rows.length,
                itemBuilder: (context, i) {
                  final r = input.rows[i];
                  return ListTile(
                    title: Text('${r['invoice_name_vi']} / ${r['unit_name']}'),
                    subtitle: Text(
                      '${r['menu_item_id'] ?? r['item_type']}\n${r['effective_from']} → ${r['effective_to'] ?? '∞'}\n${r['mapping_version']}',
                    ),
                  );
                },
              ),
            ),
          if (_message != null)
            Text(
              _message!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: _saving ? null : () => Navigator.pop(context),
        child: Text(copy('닫기', 'Đóng', 'Close')),
      ),
      FilledButton(
        onPressed: _saving || _input == null ? null : _approve,
        child: Text(
          copy(
            '검토한 매핑 승인',
            'Duyệt ánh xạ đã kiểm tra',
            'Approve reviewed mappings',
          ),
        ),
      ),
    ],
  );
}
