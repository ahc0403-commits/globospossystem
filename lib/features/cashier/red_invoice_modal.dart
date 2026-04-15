import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../main.dart';
import '../../core/services/einvoice_service.dart';
import '../../widgets/error_toast.dart';

enum _BuyerLookupState { idle, cacheHit, wt09Hit, manualFallback }

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
  final _companyCtrl = TextEditingController();
  final _addressCtrl = TextEditingController();
  final _emailCtrl = TextEditingController();
  final _emailCcCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();

  bool _isLookingUp = false;
  _BuyerLookupState _lookupState = _BuyerLookupState.idle;
  String? _lookupNote;

  @override
  void dispose() {
    _taxCodeCtrl.dispose();
    _companyCtrl.dispose();
    _addressCtrl.dispose();
    _emailCtrl.dispose();
    _emailCcCtrl.dispose();
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
        _companyCtrl.text = cached['tax_company_name'] ?? '';
        _addressCtrl.text = cached['tax_address'] ?? '';
        _emailCtrl.text = cached['receiver_email'] ?? '';
        _emailCcCtrl.text = cached['receiver_email_cc'] ?? '';
        setState(() {
          _lookupState = _BuyerLookupState.cacheHit;
          _lookupNote = 'Known buyer loaded from store or tax-entity cache.';
        });
        return;
      }

      final company = await einvoiceService.lookupCompanyByTaxCode(normalized);
      if (!mounted) return;
      if (company != null) {
        _companyCtrl.text = company['tax_company_name'] ?? _companyCtrl.text;
        _addressCtrl.text = company['tax_address'] ?? _addressCtrl.text;
        if (_emailCtrl.text.trim().isEmpty) {
          _emailCtrl.text = company['receiver_email'] ?? '';
        }
        setState(() {
          _lookupState = _BuyerLookupState.wt09Hit;
          _lookupNote = 'WT09 company lookup filled legal name and address.';
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
            _lookupNote =
                'No cache or live WT09 match. Continue with manual entry.';
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
        receiverEmailCc: _emailCcCtrl.text.trim().isEmpty
            ? null
            : _emailCcCtrl.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(true); // true = submitted
    } catch (e) {
      if (mounted) showErrorToast(context, 'Failed to request red invoice: $e');
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      title: Row(
        children: [
          const Icon(Icons.receipt_long, color: AppColors.amber500, size: 22),
          const SizedBox(width: 8),
          Text(
            'Red Invoice (Hóa Đơn Đỏ)',
            style: GoogleFonts.notoSansKr(
              color: AppColors.textPrimary,
              fontWeight: FontWeight.w700,
              fontSize: 17,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 420,
        child: _showForm ? _buildForm() : _buildPrompt(),
      ),
      actions: _showForm ? _buildFormActions() : _buildPromptActions(),
    );
  }

  Widget _buildPrompt() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Text(
        'Does this customer need a red invoice?',
        style: GoogleFonts.notoSansKr(
          color: AppColors.textSecondary,
          fontSize: 15,
        ),
      ),
    );
  }

  List<Widget> _buildPromptActions() {
    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(false),
        child: Text(
          'No',
          style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
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
          'Yes, issue invoice',
          style: GoogleFonts.notoSansKr(fontWeight: FontWeight.w700),
        ),
      ),
    ];
  }

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 8),
          _label('Tax Code'),
          Row(
            children: [
              Expanded(
                child: _field(
                  controller: _taxCodeCtrl,
                  hint: 'e.g. 0312345678',
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
                        child: const Text('Lookup'),
                      ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          _lookupStatusPanel(),
          const SizedBox(height: 10),
          _label('Company Name'),
          _field(
            controller: _companyCtrl,
            hint: 'GLOBOSVN Co., Ltd.',
            required: false,
          ),
          const SizedBox(height: 10),
          _label('Address'),
          _field(
            controller: _addressCtrl,
            hint: 'Registered address',
            required: false,
          ),
          const SizedBox(height: 10),
          _label('Email *'),
          _field(
            controller: _emailCtrl,
            hint: 'invoice@company.com',
            required: true,
            keyboardType: TextInputType.emailAddress,
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Email is required';
              if (!v.contains('@')) return 'Invalid email';
              return null;
            },
          ),
          const SizedBox(height: 10),
          _label('CC Email (optional)'),
          _field(
            controller: _emailCcCtrl,
            hint: 'cc@company.com',
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
          'Back',
          style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
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
                'Submit',
                style: GoogleFonts.notoSansKr(fontWeight: FontWeight.w700),
              ),
      ),
    ];
  }

  Widget _lookupStatusPanel() {
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
          'Enter a tax code to check store cache first, then WT09 if nothing is cached.',
          style: GoogleFonts.notoSansKr(
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
        'Cache Match',
      ),
      _BuyerLookupState.wt09Hit => (
        AppColors.amber500,
        Icons.cloud_sync_outlined,
        'WT09 Auto-Fill',
      ),
      _BuyerLookupState.manualFallback => (
        AppColors.statusOccupied,
        Icons.edit_note,
        'Manual Entry',
      ),
      _ => (AppColors.textSecondary, Icons.info_outline, 'Buyer Lookup'),
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
                  style: GoogleFonts.notoSansKr(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  _lookupNote ?? '',
                  style: GoogleFonts.notoSansKr(
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
        style: GoogleFonts.notoSansKr(
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
      style: GoogleFonts.notoSansKr(color: AppColors.textPrimary, fontSize: 14),
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: GoogleFonts.notoSansKr(
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
