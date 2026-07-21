import 'dart:typed_data';

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/app_fonts.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../core/ui/toast/toast.dart';
import '../../widgets/app_nav_bar.dart';
import '../restaurant_sales_export/restaurant_sales_export.dart';
import 'red_invoice_intake_models.dart';
import 'red_invoice_intake_service.dart';

class RedInvoiceIntakeScreen extends StatefulWidget {
  const RedInvoiceIntakeScreen({super.key, this.service});

  final RedInvoiceIntakeService? service;

  @override
  State<RedInvoiceIntakeScreen> createState() => _RedInvoiceIntakeScreenState();
}

class _RedInvoiceIntakeScreenState extends State<RedInvoiceIntakeScreen> {
  late String _businessDate;
  List<RedInvoiceIntake> _requests = const [];
  bool _isLoading = false;
  bool _isExporting = false;
  String? _error;

  RedInvoiceIntakeService get _service =>
      widget.service ?? redInvoiceIntakeService;

  @override
  void initState() {
    super.initState();
    _businessDate = restaurantHcmBusinessDate(DateTime.now());
    _reload();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final awaiting = _requests
        .where((request) => request.status == 'awaiting_information')
        .length;
    final ready = _requests
        .where((request) => request.status == 'ready')
        .length;
    final exported = _requests
        .where((request) => request.status == 'exported')
        .length;

    return Scaffold(
      key: const Key('red_invoice_intake_screen'),
      backgroundColor: ToastColorTokens.canvas,
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1120),
            child: RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                padding: const EdgeInsets.all(24),
                children: [
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: AppNavBar(),
                  ),
                  const SizedBox(height: ToastSpacingTokens.xxl),
                  ToastWorkSurface(
                    padding: const EdgeInsets.all(ToastSpacingTokens.xl),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(
                          l10n.redInvoiceIntakeTitle,
                          style: AppFonts.system(
                            color: ToastColorTokens.textPrimary,
                            fontSize: 26,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          l10n.redInvoiceIntakeSubtitle,
                          style: AppFonts.system(
                            color: ToastColorTokens.textSecondary,
                            fontSize: 14,
                            height: 1.45,
                          ),
                        ),
                        const SizedBox(height: 20),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            OutlinedButton.icon(
                              onPressed: _isLoading ? null : _chooseDate,
                              icon: const Icon(Icons.calendar_month_outlined),
                              label: Text(_businessDate),
                            ),
                            OutlinedButton.icon(
                              onPressed: _isLoading ? null : _reload,
                              icon: const Icon(Icons.refresh),
                              label: Text(l10n.refresh),
                            ),
                            FilledButton.icon(
                              key: const Key('red_invoice_export_button'),
                              onPressed: _isExporting || _isLoading
                                  ? null
                                  : _export,
                              icon: _isExporting
                                  ? const SizedBox.square(
                                      dimension: 18,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                      ),
                                    )
                                  : const Icon(Icons.download_outlined),
                              label: Text(l10n.redInvoiceExportExcel),
                            ),
                          ],
                        ),
                        const SizedBox(height: 16),
                        Wrap(
                          spacing: 10,
                          runSpacing: 10,
                          children: [
                            _metric(l10n.redInvoiceStatusAwaiting, awaiting),
                            _metric(l10n.redInvoiceStatusReady, ready),
                            _metric(l10n.redInvoiceStatusExported, exported),
                            _metric(l10n.total, _requests.length),
                          ],
                        ),
                        if (_error != null) ...[
                          const SizedBox(height: 16),
                          _messagePanel(_error!, isError: true),
                        ],
                      ],
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (_isLoading)
                    const Padding(
                      padding: EdgeInsets.all(48),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_requests.isEmpty)
                    ToastWorkSurface(
                      padding: const EdgeInsets.all(32),
                      child: Text(
                        l10n.redInvoiceIntakeEmpty,
                        textAlign: TextAlign.center,
                      ),
                    )
                  else
                    ..._requests.map(_requestCard),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _metric(String label, int value) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: ToastColorTokens.mutedSurface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ToastColorTokens.border),
      ),
      child: Text(
        '$label $value',
        style: AppFonts.system(
          color: ToastColorTokens.textPrimary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _requestCard(RedInvoiceIntake request) {
    final l10n = context.l10n;
    final canEdit =
        request.status != 'exported' && request.status != 'completed';
    final amount = NumberFormat('#,##0', 'vi_VN').format(request.grossAmount);
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: ToastWorkSurface(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: 12,
              runSpacing: 8,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(
                  request.storeName,
                  style: AppFonts.system(
                    color: ToastColorTokens.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                _statusChip(request.status),
                Text(
                  '$amount VND',
                  style: AppFonts.system(
                    color: ToastColorTokens.textPrimary,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Text(
              '${l10n.redInvoiceOrderId}: ${request.orderId}\n'
              '${l10n.redInvoiceReceiptIds}: ${request.receiptIds.join(', ')}\n'
              '${l10n.redInvoiceInformationSource}: ${_sourceLabel(request.source)}\n'
              '${l10n.redInvoiceAttachments}: ${request.attachmentUrls.length}',
              style: AppFonts.system(
                color: ToastColorTokens.textSecondary,
                fontSize: 12,
                height: 1.45,
              ),
            ),
            if (request.sourceNote.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                request.sourceNote,
                style: AppFonts.system(
                  color: ToastColorTokens.textPrimary,
                  fontSize: 13,
                ),
              ),
            ],
            if (request.buyerLegalName.isNotEmpty ||
                request.buyerTaxCode.isNotEmpty) ...[
              const SizedBox(height: 10),
              Text(
                '${request.buyerLegalName} · ${request.buyerTaxCode}\n'
                '${request.buyerAddress}\n${request.buyerEmail}',
                style: AppFonts.system(
                  color: ToastColorTokens.textPrimary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
            ],
            if (request.attachmentUrls.isNotEmpty) ...[
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (
                    var index = 0;
                    index < request.attachmentUrls.length;
                    index++
                  )
                    OutlinedButton.icon(
                      onPressed: () =>
                          _openAttachment(request.attachmentUrls[index]),
                      icon: const Icon(Icons.open_in_new, size: 16),
                      label: Text(l10n.redInvoiceOpenAttachment(index + 1)),
                    ),
                ],
              ),
            ],
            if (canEdit) ...[
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerRight,
                child: OutlinedButton.icon(
                  key: Key('red_invoice_edit_${request.id}'),
                  onPressed: () => _edit(request),
                  icon: const Icon(Icons.edit_outlined),
                  label: Text(l10n.edit),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statusChip(String status) {
    final color = switch (status) {
      'ready' => ToastColorTokens.success,
      'exported' || 'completed' => ToastColorTokens.info,
      'manual_review' || 'cancelled' => ToastColorTokens.danger,
      _ => ToastColorTokens.warning,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.45)),
      ),
      child: Text(
        _statusLabel(status),
        style: AppFonts.system(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  Widget _messagePanel(String message, {required bool isError}) {
    final color = isError ? ToastColorTokens.danger : ToastColorTokens.success;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color),
      ),
      child: Text(message),
    );
  }

  Future<void> _chooseDate() async {
    final selected = await showDatePicker(
      context: context,
      initialDate: DateTime.parse(_businessDate),
      firstDate: DateTime(2020),
      lastDate: DateTime.parse(restaurantHcmBusinessDate(DateTime.now())),
    );
    if (selected == null) return;
    setState(() {
      _businessDate = DateFormat('yyyy-MM-dd').format(selected);
    });
    await _reload();
  }

  Future<void> _reload() async {
    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      final requests = await _service.load(_businessDate);
      if (!mounted) return;
      setState(() => _requests = requests);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _edit(RedInvoiceIntake request) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) =>
          _RedInvoiceIntakeEditDialog(request: request, service: _service),
    );
    if (saved == true) await _reload();
  }

  Future<void> _openAttachment(String url) async {
    final opened = await launchUrl(
      Uri.parse(url),
      mode: LaunchMode.externalApplication,
    );
    if (!opened && mounted) {
      setState(() => _error = context.l10n.redInvoiceAttachmentOpenFailed);
    }
  }

  Future<void> _export() async {
    setState(() {
      _isExporting = true;
      _error = null;
    });
    try {
      final export = await _service.loadExport(_businessDate);
      if (export.status != 'finalized') {
        throw const FormatException('RED_INVOICE_EXPORT_NOT_READY');
      }
      if (export.requests.isEmpty) {
        throw const FormatException('RED_INVOICE_EXPORT_EMPTY');
      }
      final batchId = const Uuid().v4();
      final bytes = buildRedInvoiceWorkbook(
        export: export,
        exportBatchId: batchId,
      );
      await FileSaver.instance.saveFile(
        name:
            'red_invoice_${_businessDate.replaceAll('-', '')}_${batchId.substring(0, 8)}',
        bytes: Uint8List.fromList(bytes),
        ext: 'xlsx',
        mimeType: MimeType.microsoftExcel,
      );
      final marked = await _service.markExported(
        intakeIds: export.requests.map((request) => request.id).toList(),
        exportBatchId: batchId,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(context.l10n.redInvoiceExportSaved(marked))),
      );
      await _reload();
    } catch (error) {
      if (!mounted) return;
      final code = error is FormatException
          ? error.message.toString()
          : '$error';
      final message = switch (code) {
        'RED_INVOICE_EXPORT_NOT_READY' => context.l10n.redInvoiceExportNotReady,
        'RED_INVOICE_EXPORT_EMPTY' => context.l10n.redInvoiceExportEmpty,
        'RED_INVOICE_EXPORT_LINE_ITEMS_REQUIRED' =>
          context.l10n.redInvoiceExportLineItemsRequired,
        _ when code.contains('RED_INVOICE_MISA_CONFIG_REQUIRED') =>
          context.l10n.redInvoiceMisaConfigRequired,
        _ when code.contains('RED_INVOICE_EXPORT_STATE_CHANGED') =>
          context.l10n.redInvoiceExportStateChanged,
        _ => context.l10n.redInvoiceExportFailed('$error'),
      };
      setState(() => _error = message);
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  String _sourceLabel(String source) {
    return switch (source) {
      'business_card' => context.l10n.redInvoiceSourceBusinessCard,
      'zalo' => context.l10n.redInvoiceSourceZalo,
      'other' => context.l10n.redInvoiceSourceOther,
      _ => context.l10n.redInvoiceSourceCashier,
    };
  }

  String _statusLabel(String status) {
    return switch (status) {
      'ready' => context.l10n.redInvoiceStatusReady,
      'exported' => context.l10n.redInvoiceStatusExported,
      'completed' => context.l10n.redInvoiceStatusCompleted,
      'manual_review' => context.l10n.redInvoiceStatusManualReview,
      'cancelled' => context.l10n.redInvoiceStatusCancelled,
      _ => context.l10n.redInvoiceStatusAwaiting,
    };
  }
}

class _RedInvoiceIntakeEditDialog extends StatefulWidget {
  const _RedInvoiceIntakeEditDialog({
    required this.request,
    required this.service,
  });

  final RedInvoiceIntake request;
  final RedInvoiceIntakeService service;

  @override
  State<_RedInvoiceIntakeEditDialog> createState() =>
      _RedInvoiceIntakeEditDialogState();
}

class _RedInvoiceIntakeEditDialogState
    extends State<_RedInvoiceIntakeEditDialog> {
  final _formKey = GlobalKey<FormState>();
  late final TextEditingController _taxCode;
  late final TextEditingController _unitCode;
  late final TextEditingController _legalName;
  late final TextEditingController _fullName;
  late final TextEditingController _address;
  late final TextEditingController _email;
  late final TextEditingController _emailCc;
  late final TextEditingController _phone;
  late final TextEditingController _buyerId;
  late final TextEditingController _note;
  late String _source;
  late String _status;
  XFile? _evidence;
  bool _saving = false;

  bool get _requiresBuyerInformation => _status == 'ready';

  @override
  void initState() {
    super.initState();
    final request = widget.request;
    _taxCode = TextEditingController(text: request.buyerTaxCode);
    _unitCode = TextEditingController(text: request.buyerUnitCode);
    _legalName = TextEditingController(text: request.buyerLegalName);
    _fullName = TextEditingController(text: request.buyerFullName);
    _address = TextEditingController(text: request.buyerAddress);
    _email = TextEditingController(text: request.buyerEmail);
    _emailCc = TextEditingController(text: request.buyerEmailCc);
    _phone = TextEditingController(text: request.buyerPhone);
    _buyerId = TextEditingController(text: request.buyerId);
    _note = TextEditingController(text: request.sourceNote);
    _source = request.source;
    _status = request.status;
  }

  @override
  void dispose() {
    for (final controller in [
      _taxCode,
      _unitCode,
      _legalName,
      _fullName,
      _address,
      _email,
      _emailCc,
      _phone,
      _buyerId,
      _note,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      key: const Key('red_invoice_intake_edit_dialog'),
      title: Text(l10n.redInvoiceEditTitle),
      content: SizedBox(
        width: 620,
        child: Form(
          key: _formKey,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _source,
                        decoration: InputDecoration(
                          labelText: l10n.redInvoiceInformationSource,
                        ),
                        items: [
                          _item('cashier', l10n.redInvoiceSourceCashier),
                          _item(
                            'business_card',
                            l10n.redInvoiceSourceBusinessCard,
                          ),
                          _item('zalo', l10n.redInvoiceSourceZalo),
                          _item('other', l10n.redInvoiceSourceOther),
                        ],
                        onChanged: (value) => setState(() => _source = value!),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: DropdownButtonFormField<String>(
                        initialValue: _status,
                        decoration: InputDecoration(
                          labelText: l10n.redInvoiceStatus,
                        ),
                        items: [
                          _item(
                            'awaiting_information',
                            l10n.redInvoiceStatusAwaiting,
                          ),
                          _item('ready', l10n.redInvoiceStatusReady),
                          _item(
                            'manual_review',
                            l10n.redInvoiceStatusManualReview,
                          ),
                          _item('cancelled', l10n.redInvoiceStatusCancelled),
                        ],
                        onChanged: (value) => setState(() => _status = value!),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                _field(
                  _taxCode,
                  l10n.redInvoiceTaxCode,
                  required: _requiresBuyerInformation,
                ),
                _field(_unitCode, l10n.redInvoiceUnitCode),
                _field(
                  _legalName,
                  l10n.redInvoiceCompanyName,
                  required: _requiresBuyerInformation,
                ),
                _field(_fullName, l10n.redInvoiceBuyerFullName),
                _field(
                  _address,
                  l10n.address,
                  required: _requiresBuyerInformation,
                ),
                _field(
                  _email,
                  l10n.redInvoiceEmailRequiredLabel,
                  required: _requiresBuyerInformation,
                  email: true,
                ),
                _field(_emailCc, l10n.redInvoiceCcEmailOptional, email: true),
                _field(_phone, l10n.redInvoicePhone),
                _field(_buyerId, l10n.redInvoiceBuyerId),
                _field(_note, l10n.redInvoiceSourceNote, lines: 3),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: _saving ? null : _pickEvidence,
                    icon: const Icon(Icons.add_photo_alternate_outlined),
                    label: Text(
                      _evidence == null
                          ? l10n.redInvoiceAttachEvidence
                          : l10n.redInvoiceEvidenceSelected(_evidence!.name),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('red_invoice_intake_edit_cancel'),
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: Text(l10n.cancel),
        ),
        FilledButton(
          onPressed: _saving ? null : _save,
          child: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(l10n.save),
        ),
      ],
    );
  }

  DropdownMenuItem<String> _item(String value, String label) {
    return DropdownMenuItem(value: value, child: Text(label));
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = false,
    bool email = false,
    int lines = 1,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: TextFormField(
        controller: controller,
        minLines: lines,
        maxLines: lines,
        decoration: InputDecoration(labelText: label),
        validator: (value) {
          final text = value?.trim() ?? '';
          if (required && text.isEmpty) {
            return context.l10n.redInvoiceRequiredField;
          }
          if (email && text.isNotEmpty && !text.contains('@')) {
            return context.l10n.redInvoiceInvalidEmail;
          }
          return null;
        },
      ),
    );
  }

  Future<void> _pickEvidence() async {
    final file = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (file != null && mounted) setState(() => _evidence = file);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final saved = await widget.service.save(
        orderId: widget.request.orderId,
        storeId: widget.request.storeId,
        source: _source,
        status: _status,
        buyerTaxCode: _taxCode.text,
        buyerUnitCode: _unitCode.text,
        buyerLegalName: _legalName.text,
        buyerFullName: _fullName.text,
        buyerAddress: _address.text,
        buyerEmail: _email.text,
        buyerEmailCc: _emailCc.text,
        buyerPhone: _phone.text,
        buyerId: _buyerId.text,
        sourceNote: _note.text,
      );
      final evidence = _evidence;
      if (evidence != null) {
        await widget.service.uploadEvidence(
          intakeId: saved.id,
          storeId: saved.storeId,
          file: evidence,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(context.l10n.redInvoiceDeferredSaveFailed('$error')),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }
}
