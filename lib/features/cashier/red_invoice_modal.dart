import 'package:flutter/material.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../widgets/error_toast.dart';
import '../red_invoice_intake/red_invoice_intake_service.dart';
import '../red_invoice_intake/buyer_information_form.dart';

enum _RedInvoiceStep { prompt, immediate, deferred }

/// Modal shown after successful payment.
/// Step 1: Ask "Red invoice?" → Step 2: Buyer form.
class RedInvoiceModal extends StatefulWidget {
  const RedInvoiceModal({
    super.key,
    required this.orderId,
    required this.storeId,
  });

  final String orderId;
  final String storeId;

  @override
  State<RedInvoiceModal> createState() => _RedInvoiceModalState();
}

class _RedInvoiceModalState extends State<RedInvoiceModal> {
  _RedInvoiceStep _step = _RedInvoiceStep.prompt;
  bool _isSubmitting = false;

  final _buyer = BuyerInformationController(const {});
  final _deferredNoteCtrl = TextEditingController();
  String _deferredSource = 'business_card';
  XFile? _deferredEvidence;

  @override
  void dispose() {
    _buyer.dispose();
    _deferredNoteCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_buyer.validate()) return;
    setState(() => _isSubmitting = true);
    try {
      await redInvoiceIntakeService.saveBuyerInformation(
        orderId: widget.orderId,
        storeId: widget.storeId,
        expectedVersion: null,
        patch: _buyer.patch,
      );
      if (!mounted) return;
      Navigator.of(context).pop(true); // true = submitted
    } catch (e) {
      if (mounted) {
        showErrorToast(context, buyerSaveError(context, _buyer, e));
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _pickDeferredEvidence() async {
    final picked = await ImagePicker().pickImage(
      source: ImageSource.gallery,
      imageQuality: 90,
    );
    if (picked != null && mounted) {
      setState(() => _deferredEvidence = picked);
    }
  }

  Future<void> _submitDeferred() async {
    final note = _deferredNoteCtrl.text.trim();
    if (_deferredSource == 'business_card' && _deferredEvidence == null) {
      showErrorToast(context, context.l10n.redInvoiceBusinessCardRequired);
      return;
    }
    if (_deferredSource != 'business_card' && note.isEmpty) {
      showErrorToast(context, context.l10n.redInvoiceSourceNoteRequired);
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final intake = await redInvoiceIntakeService.save(
        orderId: widget.orderId,
        storeId: widget.storeId,
        source: _deferredSource,
        status: 'awaiting_information',
        sourceNote: note,
      );
      final evidence = _deferredEvidence;
      if (evidence != null) {
        await redInvoiceIntakeService.uploadEvidence(
          intakeId: intake.id,
          storeId: widget.storeId,
          file: evidence,
        );
      }
      if (!mounted) return;
      Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) {
        showErrorToast(
          context,
          context.l10n.redInvoiceDeferredSaveFailed('$error'),
        );
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      backgroundColor: PosColors.surface,
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      title: Row(
        children: [
          const Icon(Icons.receipt_long, color: PosColors.accent, size: 22),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              l10n.redInvoiceTitle,
              style: AppFonts.system(
                color: PosColors.textPrimary,
                fontWeight: FontWeight.w700,
                fontSize: 17,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: switch (_step) {
          _RedInvoiceStep.immediate => ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 560),
            child: SingleChildScrollView(child: _buildForm()),
          ),
          _RedInvoiceStep.deferred => _buildDeferredForm(),
          _RedInvoiceStep.prompt => _buildPrompt(),
        },
      ),
      actions: switch (_step) {
        _RedInvoiceStep.immediate => _buildFormActions(),
        _RedInvoiceStep.deferred => _buildDeferredActions(),
        _RedInvoiceStep.prompt => _buildPromptActions(),
      },
    );
  }

  Widget _buildPrompt() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        context.l10n.redInvoicePrompt,
        style: AppFonts.system(color: PosColors.textSecondary, fontSize: 15),
      ),
    );
  }

  List<Widget> _buildPromptActions() {
    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(
          context.l10n.no,
          style: AppFonts.system(color: PosColors.textSecondary),
        ),
      ),
      OutlinedButton.icon(
        onPressed: () => setState(() => _step = _RedInvoiceStep.deferred),
        icon: const Icon(Icons.schedule_send_outlined, size: 16),
        label: Text(context.l10n.redInvoiceCollectLater),
      ),
      FilledButton.icon(
        onPressed: () => setState(() => _step = _RedInvoiceStep.immediate),
        style: FilledButton.styleFrom(
          backgroundColor: PosColors.accent,
          foregroundColor: Colors.white,
        ),
        icon: const Icon(Icons.receipt_long, size: 16),
        label: Text(
          context.l10n.redInvoiceIssueInvoice,
          style: AppFonts.system(fontWeight: FontWeight.w700),
        ),
      ),
    ];
  }

  Widget _buildDeferredForm() {
    final l10n = context.l10n;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 500),
      child: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(height: 8),
            Text(
              l10n.redInvoiceDeferredDescription,
              style: AppFonts.system(
                color: PosColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            _label(l10n.redInvoiceInformationSource),
            DropdownButtonFormField<String>(
              initialValue: _deferredSource,
              decoration: _inputDecoration(),
              items: [
                DropdownMenuItem(
                  value: 'business_card',
                  child: Text(l10n.redInvoiceSourceBusinessCard),
                ),
                DropdownMenuItem(
                  value: 'zalo',
                  child: Text(l10n.redInvoiceSourceZalo),
                ),
                DropdownMenuItem(
                  value: 'other',
                  child: Text(l10n.redInvoiceSourceOther),
                ),
              ],
              onChanged: _isSubmitting
                  ? null
                  : (value) {
                      if (value != null) {
                        setState(() => _deferredSource = value);
                      }
                    },
            ),
            const SizedBox(height: 12),
            _label(l10n.redInvoiceSourceNote),
            TextField(
              controller: _deferredNoteCtrl,
              minLines: 3,
              maxLines: 5,
              decoration: _inputDecoration(
                hintText: l10n.redInvoiceSourceNoteHint,
              ),
            ),
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _isSubmitting ? null : _pickDeferredEvidence,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: Text(
                _deferredEvidence == null
                    ? l10n.redInvoiceAttachEvidence
                    : l10n.redInvoiceEvidenceSelected(_deferredEvidence!.name),
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _buildDeferredActions() {
    return [
      TextButton(
        onPressed: _isSubmitting
            ? null
            : () => setState(() => _step = _RedInvoiceStep.prompt),
        child: Text(context.l10n.back),
      ),
      FilledButton(
        onPressed: _isSubmitting ? null : _submitDeferred,
        child: _isSubmitting
            ? const SizedBox.square(
                dimension: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : Text(context.l10n.redInvoiceSaveForLater),
      ),
    ];
  }

  Widget _buildForm() => Column(
    mainAxisSize: MainAxisSize.min,
    children: [
      BuyerInformationFields(controller: _buyer, storeId: widget.storeId),
    ],
  );

  List<Widget> _buildFormActions() {
    return [
      TextButton(
        onPressed: _isSubmitting
            ? null
            : () => setState(() => _step = _RedInvoiceStep.prompt),
        child: Text(
          context.l10n.back,
          style: AppFonts.system(color: PosColors.textSecondary),
        ),
      ),
      FilledButton(
        onPressed: _isSubmitting ? null : _submit,
        style: FilledButton.styleFrom(
          backgroundColor: PosColors.accent,
          foregroundColor: Colors.white,
        ),
        child: _isSubmitting
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : Text(
                context.l10n.redInvoiceSubmit,
                style: AppFonts.system(fontWeight: FontWeight.w700),
              ),
      ),
    ];
  }

  Widget _label(String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text,
        style: AppFonts.system(
          color: PosColors.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({String? hintText}) {
    return InputDecoration(
      hintText: hintText,
      hintStyle: AppFonts.system(color: PosColors.textSecondary, fontSize: 13),
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      filled: true,
      fillColor: PosColors.canvas,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: PosColors.border),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: PosColors.border),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: const BorderSide(color: PosColors.accent),
      ),
    );
  }
}
