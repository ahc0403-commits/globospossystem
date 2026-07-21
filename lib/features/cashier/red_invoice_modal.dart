import 'package:flutter/material.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/services/einvoice_service.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../widgets/error_toast.dart';
import '../red_invoice_intake/red_invoice_intake_service.dart';

enum _BuyerLookupState { idle, cacheHit, manualFallback }

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

  final _taxCodeCtrl = TextEditingController();
  final _unitCodeCtrl = TextEditingController();
  final _companyCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _buyerFullNameCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _emailCcCtrl = TextEditingController();
  final _phoneCtrl = TextEditingController();
  final _buyerIdCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  final _deferredNoteCtrl = TextEditingController();
  String _deferredSource = 'business_card';
  XFile? _deferredEvidence;

  bool _isLookingUp = false;
  _BuyerLookupState _lookupState = _BuyerLookupState.idle;
  String? _lookupNote;

  @override
  void dispose() {
    _taxCodeCtrl.dispose();
    _unitCodeCtrl.dispose();
    _companyCtrl.dispose();
    _addressCtrl.dispose();
    _buyerFullNameCtrl.dispose();
    _emailCtrl.dispose();
    _emailCcCtrl.dispose();
    _phoneCtrl.dispose();
    _buyerIdCtrl.dispose();
    _deferredNoteCtrl.dispose();
    super.dispose();
  }

  Future<void> _onTaxCodeSubmitted(String taxCode) async {
    final normalized = taxCode.trim();
    if (normalized.isEmpty) return;
    setState(() => _isLookingUp = true);

    try {
      final cached = await einvoiceService.lookupB2bBuyer(
        storeId: widget.storeId,
        taxCode: normalized,
      );
      if (!mounted) return;
      if (cached != null) {
        _unitCodeCtrl.text = cached['buyer_unit_code'] ?? '';
        _companyCtrl.text = cached['tax_company_name'] ?? '';
        _addressCtrl.text = cached['tax_address'] ?? '';
        _buyerFullNameCtrl.text =
            cached['buyer_full_name'] ?? cached['tax_buyer_name'] ?? '';
        _phoneCtrl.text = cached['buyer_phone'] ?? '';
        _buyerIdCtrl.text = cached['buyer_id'] ?? '';
        _emailCtrl.text = cached['receiver_email'] ?? '';
        _emailCcCtrl.text = cached['receiver_email_cc'] ?? '';
        setState(() {
          _lookupState = _BuyerLookupState.cacheHit;
          _lookupNote = context.l10n.redInvoiceCacheHitNote;
        });
        return;
      }
    } catch (_) {
      // graceful fallback: manual entry remains valid
    } finally {
      if (mounted) {
        setState(() {
          if (_lookupState == _BuyerLookupState.idle) {
            _lookupState = _BuyerLookupState.manualFallback;
            _lookupNote = context.l10n.redInvoiceManualFallbackNote;
          }
          _isLookingUp = false;
        });
      }
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);
    try {
      await einvoiceService.requestRedInvoice(
        orderId: widget.orderId,
        storeId: widget.storeId,
        receiverEmail: _emailCtrl.text.trim(),
        buyerTaxCode: _taxCodeCtrl.text.trim(),
        buyerName: _companyCtrl.text.trim(),
        buyerAddress: _addressCtrl.text.trim(),
        unitCode: _unitCodeCtrl.text.trim(),
        unitName: _companyCtrl.text.trim(),
        buyerFullName: _buyerFullNameCtrl.text.trim(),
        buyerTel: _phoneCtrl.text.trim(),
        buyerId: _buyerIdCtrl.text.trim(),
        receiverEmailCc: _emailCcCtrl.text.trim().isEmpty
            ? null
            : _emailCcCtrl.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true); // true = submitted
    } catch (e) {
      if (mounted) {
        showErrorToast(context, context.l10n.redInvoiceRequestFailed('$e'));
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

  Widget _buildForm() {
    final l10n = context.l10n;
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          _label(l10n.redInvoiceTaxCode),
          Row(
            children: [
              Expanded(
                child: _field(
                  controller: _taxCodeCtrl,
                  hint: l10n.redInvoiceTaxCodeHint,
                  required: true,
                  validator: (value) => value == null || value.trim().isEmpty
                      ? l10n.redInvoiceTaxCodeRequired
                      : null,
                  onFieldSubmitted: _onTaxCodeSubmitted,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: PosDensity.touchTargetMin,
                child: _isLookingUp
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: PosColors.accent,
                          ),
                        ),
                      )
                    : OutlinedButton(
                        onPressed: () => _onTaxCodeSubmitted(_taxCodeCtrl.text),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: PosColors.border),
                          foregroundColor: PosColors.textSecondary,
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                        ),
                        child: Text(l10n.lookup),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _lookupStatusPanel(),
          const SizedBox(height: 10),
          _label(l10n.redInvoiceUnitCode),
          _field(
            controller: _unitCodeCtrl,
            hint: l10n.redInvoiceUnitCodeHint,
            required: false,
          ),
          const SizedBox(height: 10),
          _label(l10n.redInvoiceCompanyName),
          _field(
            controller: _companyCtrl,
            hint: l10n.redInvoiceCompanyNameHint,
            required: true,
            validator: (value) => value == null || value.trim().isEmpty
                ? l10n.redInvoiceCompanyNameRequired
                : null,
          ),
          const SizedBox(height: 10),
          _label(l10n.address),
          _field(
            controller: _addressCtrl,
            hint: l10n.redInvoiceAddressHint,
            required: true,
            validator: (value) => value == null || value.trim().isEmpty
                ? l10n.redInvoiceAddressRequired
                : null,
          ),
          const SizedBox(height: 10),
          _label(l10n.redInvoiceBuyerFullName),
          _field(
            controller: _buyerFullNameCtrl,
            hint: l10n.redInvoiceBuyerFullNameHint,
            required: false,
          ),
          const SizedBox(height: 10),
          _label(l10n.redInvoicePhone),
          _field(
            controller: _phoneCtrl,
            hint: l10n.redInvoicePhoneHint,
            required: false,
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 10),
          _label(l10n.redInvoiceBuyerId),
          _field(
            controller: _buyerIdCtrl,
            hint: l10n.redInvoiceBuyerIdHint,
            required: false,
          ),
          const SizedBox(height: 10),
          _label(l10n.redInvoiceEmailRequiredLabel),
          _field(
            controller: _emailCtrl,
            hint: l10n.redInvoiceEmailHint,
            required: true,
            keyboardType: TextInputType.emailAddress,
            validator: (v) {
              if (v == null || v.trim().isEmpty) {
                return l10n.redInvoiceEmailRequired;
              }
              if (!v.contains('@')) return l10n.redInvoiceInvalidEmail;
              return null;
            },
          ),
          const SizedBox(height: 10),
          _label(l10n.redInvoiceCcEmailOptional),
          _field(
            controller: _emailCcCtrl,
            hint: l10n.redInvoiceCcEmailHint,
            required: false,
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 16),
        ],
      ),
    );
  }

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

  Widget _lookupStatusPanel() {
    final l10n = context.l10n;
    if (_lookupState == _BuyerLookupState.idle) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: PosColors.canvas,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: PosColors.border),
        ),
        child: Text(
          l10n.redInvoiceLookupIdle,
          style: AppFonts.system(
            color: PosColors.textSecondary,
            fontSize: 12,
            height: 1.35,
          ),
        ),
      );
    }

    final (color, icon, title) = switch (_lookupState) {
      _BuyerLookupState.cacheHit => (
        PosColors.success,
        Icons.inventory_2_outlined,
        l10n.redInvoiceCacheMatch,
      ),
      _BuyerLookupState.manualFallback => (
        PosColors.warning,
        Icons.edit_note,
        l10n.redInvoiceManualEntry,
      ),
      _ => (
        PosColors.textSecondary,
        Icons.info_outline,
        l10n.redInvoiceBuyerLookup,
      ),
    };

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: AppFonts.system(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _lookupNote ?? '',
                  style: AppFonts.system(
                    color: PosColors.textPrimary,
                    fontSize: 12,
                    height: 1.35,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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

  Widget _field({
    required TextEditingController controller,
    required String hint,
    required bool required,
    TextInputType? keyboardType,
    String? Function(String?)? validator,
    void Function(String)? onFieldSubmitted,
  }) {
    return TextFormField(
      controller: controller,
      keyboardType: keyboardType,
      onFieldSubmitted: onFieldSubmitted,
      style: AppFonts.system(color: PosColors.textPrimary, fontSize: 14),
      decoration: _inputDecoration(hintText: hint),
      validator: validator,
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
