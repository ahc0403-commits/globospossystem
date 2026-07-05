import 'package:flutter/material.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/services/einvoice_service.dart';
import '../../main.dart';
import '../../widgets/error_toast.dart';

enum _BuyerLookupState { idle, cacheHit, manualFallback }

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
  bool _showForm = false;
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

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      title: Row(
        children: [
          const Icon(Icons.receipt_long, color: AppColors.amber500, size: 22),
          const SizedBox(width: 8),
          Text(
            l10n.redInvoiceTitle,
            style: AppFonts.system(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 17,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: _showForm
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 560),
                child: SingleChildScrollView(child: _buildForm()),
              )
            : _buildPrompt(),
      ),
      actions: _showForm ? _buildFormActions() : _buildPromptActions(),
    );
  }

  Widget _buildPrompt() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        context.l10n.redInvoicePrompt,
        style: AppFonts.system(color: AppColors.textSecondary, fontSize: 15),
      ),
    );
  }

  List<Widget> _buildPromptActions() {
    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(
          context.l10n.no,
          style: AppFonts.system(color: AppColors.textSecondary),
        ),
      ),
      FilledButton.icon(
        onPressed: () => setState(() => _showForm = true),
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.amber500,
          foregroundColor: AppColors.surface0,
        ),
        icon: const Icon(Icons.receipt_long, size: 16),
        label: Text(
          context.l10n.redInvoiceIssueInvoice,
          style: AppFonts.system(fontWeight: FontWeight.w700),
        ),
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
                  required: false,
                  onFieldSubmitted: _onTaxCodeSubmitted,
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                height: 44,
                child: _isLookingUp
                    ? const Padding(
                        padding: EdgeInsets.all(10),
                        child: SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: AppColors.amber500,
                          ),
                        ),
                      )
                    : OutlinedButton(
                        onPressed: () => _onTaxCodeSubmitted(_taxCodeCtrl.text),
                        style: OutlinedButton.styleFrom(
                          side: const BorderSide(color: AppColors.surface2),
                          foregroundColor: AppColors.textSecondary,
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
            required: false,
          ),
          const SizedBox(height: 10),
          _label(l10n.address),
          _field(
            controller: _addressCtrl,
            hint: l10n.redInvoiceAddressHint,
            required: false,
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
            : () => setState(() => _showForm = false),
        child: Text(
          context.l10n.back,
          style: AppFonts.system(color: AppColors.textSecondary),
        ),
      ),
      FilledButton(
        onPressed: _isSubmitting ? null : _submit,
        style: FilledButton.styleFrom(
          backgroundColor: AppColors.amber500,
          foregroundColor: AppColors.surface0,
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
          color: AppColors.surface0,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.surface2),
        ),
        child: Text(
          l10n.redInvoiceLookupIdle,
          style: AppFonts.system(
            color: AppColors.textSecondary,
            fontSize: 12,
            height: 1.35,
          ),
        ),
      );
    }

    final (color, icon, title) = switch (_lookupState) {
      _BuyerLookupState.cacheHit => (
        AppColors.statusAvailable,
        Icons.inventory_2_outlined,
        l10n.redInvoiceCacheMatch,
      ),
      _BuyerLookupState.manualFallback => (
        AppColors.statusOccupied,
        Icons.edit_note,
        l10n.redInvoiceManualEntry,
      ),
      _ => (
        AppColors.textSecondary,
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
                    color: AppColors.textPrimary,
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
          color: AppColors.textSecondary,
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
      style: AppFonts.system(color: AppColors.textPrimary, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: AppFonts.system(
          color: AppColors.textSecondary,
          fontSize: 13,
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        filled: true,
        fillColor: AppColors.surface0,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.surface2),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.surface2),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.amber500),
        ),
      ),
      validator: validator,
    );
  }
}
