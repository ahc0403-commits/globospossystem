import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/layout/platform_info.dart';
import '../../core/services/discount_proof_service.dart';
import '../../core/services/discount_service.dart';
import '../../core/ui/app_fonts.dart';
import '../../main.dart';
import '../../widgets/error_toast.dart';

class DiscountModal extends StatefulWidget {
  const DiscountModal({
    super.key,
    required this.orderId,
    required this.storeId,
    required this.menuSubtotal,
    required this.serviceChargeTotal,
  });

  final String orderId;
  final String storeId;
  final double menuSubtotal;
  final double serviceChargeTotal;

  @override
  State<DiscountModal> createState() => _DiscountModalState();
}

class _DiscountModalState extends State<DiscountModal> {
  final _valueController = TextEditingController();
  final _reasonController = TextEditingController();
  final _couponController = TextEditingController();
  final _pinController = TextEditingController();
  final _picker = ImagePicker();

  String _type = 'manual';
  String _mode = 'amount';
  XFile? _selectedFile;
  Uint8List? _previewBytes;
  bool _isSaving = false;

  double get _previewDiscountAmount {
    final value = double.tryParse(_valueController.text.trim());
    if (value == null || value <= 0) return 0;
    final rawDiscount = _mode == 'percent'
        ? widget.menuSubtotal * value / 100
        : value;
    return _roundMoney(rawDiscount.clamp(0, widget.menuSubtotal).toDouble());
  }

  double get _previewPayable {
    return _roundMoney(
      widget.menuSubtotal + widget.serviceChargeTotal - _previewDiscountAmount,
    );
  }

  @override
  void dispose() {
    _valueController.dispose();
    _reasonController.dispose();
    _couponController.dispose();
    _pinController.dispose();
    super.dispose();
  }

  Future<void> _pickPhoto() async {
    try {
      final source = PlatformInfo.isAndroid
          ? ImageSource.camera
          : ImageSource.gallery;
      final picked = await _picker.pickImage(source: source, imageQuality: 90);
      if (picked == null || !mounted) return;
      final preview = await picked.readAsBytes();
      setState(() {
        _selectedFile = picked;
        _previewBytes = preview;
      });
    } catch (e) {
      if (!mounted) return;
      showErrorToast(context, context.l10n.cashierDiscountProofFailed('$e'));
    }
  }

  Future<void> _apply() async {
    final value = double.tryParse(_valueController.text.trim());
    final file = _selectedFile;
    if (value == null || value <= 0) {
      showErrorToast(context, context.l10n.cashierDiscountValueRequired);
      return;
    }
    if (_pinController.text.trim().isEmpty) {
      showErrorToast(context, context.l10n.cashierDiscountPinRequired);
      return;
    }
    if (file == null) {
      showErrorToast(context, context.l10n.cashierDiscountProofRequired);
      return;
    }

    setState(() => _isSaving = true);
    try {
      final proofPath = await discountProofService.uploadProof(
        orderId: widget.orderId,
        storeId: widget.storeId,
        originalFile: file,
      );
      final discount = await discountService.applyOrderDiscount(
        orderId: widget.orderId,
        storeId: widget.storeId,
        type: _type,
        mode: _mode,
        value: value,
        reason: _reasonController.text.trim(),
        couponCode: _couponController.text.trim(),
        proofStoragePath: proofPath,
        managerPin: _pinController.text.trim(),
      );
      if (!mounted) return;
      Navigator.of(context).pop(discount);
    } catch (e) {
      if (!mounted) return;
      showErrorToast(context, context.l10n.cashierDiscountApplyFailed('$e'));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    final currency = NumberFormat('#,###', 'vi_VN');
    final originalTotal = widget.menuSubtotal + widget.serviceChargeTotal;
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      contentPadding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
      title: Row(
        children: [
          const Icon(Icons.local_offer_outlined, color: AppColors.amber500),
          const SizedBox(width: 8),
          Text(
            l10n.cashierDiscountTitle,
            style: AppTextStyles.operationalTitle(
              size: 24,
              color: AppColors.textPrimary,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _type,
                      decoration: InputDecoration(
                        labelText: l10n.cashierDiscountType,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'manual',
                          child: Text(l10n.cashierDiscountTypeManual),
                        ),
                        DropdownMenuItem(
                          value: 'coupon',
                          child: Text(l10n.cashierDiscountTypeCoupon),
                        ),
                        DropdownMenuItem(
                          value: 'promotion',
                          child: Text(l10n.cashierDiscountTypePromotion),
                        ),
                      ],
                      onChanged: _isSaving
                          ? null
                          : (value) =>
                                setState(() => _type = value ?? 'manual'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: DropdownButtonFormField<String>(
                      initialValue: _mode,
                      decoration: InputDecoration(
                        labelText: l10n.cashierDiscountMode,
                      ),
                      items: [
                        DropdownMenuItem(
                          value: 'amount',
                          child: Text(l10n.cashierDiscountAmountMode),
                        ),
                        DropdownMenuItem(
                          value: 'percent',
                          child: Text(l10n.cashierDiscountPercentMode),
                        ),
                      ],
                      onChanged: _isSaving
                          ? null
                          : (value) =>
                                setState(() => _mode = value ?? 'amount'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _valueController,
                keyboardType: TextInputType.number,
                onChanged: (_) => setState(() {}),
                decoration: InputDecoration(
                  labelText: l10n.cashierDiscountValue,
                ),
              ),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface0,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppColors.surface2),
                ),
                child: Column(
                  children: [
                    _DiscountPreviewLine(
                      label: l10n.cashierSubtotal,
                      value: '₫${currency.format(originalTotal)}',
                    ),
                    _DiscountPreviewLine(
                      label: l10n.cashierDiscountSummary,
                      value: '-₫${currency.format(_previewDiscountAmount)}',
                      valueColor: AppColors.statusReady,
                    ),
                    const Divider(height: 16),
                    _DiscountPreviewLine(
                      label: l10n.cashierPaymentDue,
                      value: '₫${currency.format(_previewPayable)}',
                      prominent: true,
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _couponController,
                decoration: InputDecoration(
                  labelText: l10n.cashierDiscountCouponCode,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _reasonController,
                minLines: 1,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: l10n.cashierDiscountReason,
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _pinController,
                keyboardType: TextInputType.number,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: l10n.cashierDiscountManagerPin,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppColors.surface0,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: AppColors.surface2),
                ),
                child: _previewBytes == null
                    ? Text(
                        l10n.cashierDiscountNoProof,
                        style: AppFonts.system(
                          color: AppColors.textSecondary,
                          fontWeight: FontWeight.w700,
                        ),
                      )
                    : ClipRRect(
                        borderRadius: BorderRadius.circular(12),
                        child: Image.memory(
                          _previewBytes!,
                          height: 180,
                          fit: BoxFit.cover,
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(null),
          child: Text(l10n.cancel),
        ),
        OutlinedButton.icon(
          onPressed: _isSaving ? null : _pickPhoto,
          icon: const Icon(Icons.photo_camera_outlined, size: 16),
          label: Text(
            _selectedFile == null
                ? l10n.cashierDiscountPickProof
                : l10n.cashierDiscountRetakeProof,
          ),
        ),
        FilledButton.icon(
          key: const Key('cashier_discount_apply_button'),
          onPressed: _isSaving ? null : _apply,
          icon: _isSaving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                )
              : const Icon(Icons.check_circle_outline, size: 16),
          label: Text(l10n.cashierDiscountApply),
        ),
      ],
    );
  }
}

class _DiscountPreviewLine extends StatelessWidget {
  const _DiscountPreviewLine({
    required this.label,
    required this.value,
    this.valueColor,
    this.prominent = false,
  });

  final String label;
  final String value;
  final Color? valueColor;
  final bool prominent;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        children: [
          Text(
            label,
            style: AppFonts.system(
              color: AppColors.textSecondary,
              fontWeight: FontWeight.w700,
            ),
          ),
          const Spacer(),
          Text(
            value,
            style: AppFonts.system(
              color: valueColor ?? AppColors.textPrimary,
              fontSize: prominent ? 17 : 14,
              fontWeight: prominent ? FontWeight.w900 : FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

double _roundMoney(double value) => (value * 100).roundToDouble() / 100;
