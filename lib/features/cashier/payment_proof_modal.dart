import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/i18n/locale_extensions.dart';
import '../../core/layout/platform_info.dart';
import '../../core/services/payment_proof_service.dart';
import '../../core/ui/pos_design_tokens.dart';
import '../../widgets/error_toast.dart';

class PaymentProofModal extends StatefulWidget {
  const PaymentProofModal({
    super.key,
    required this.paymentId,
    required this.storeId,
    required this.methodLabel,
  });

  final String paymentId;
  final String storeId;
  final String methodLabel;

  @override
  State<PaymentProofModal> createState() => _PaymentProofModalState();
}

class _PaymentProofModalState extends State<PaymentProofModal> {
  final ImagePicker _picker = ImagePicker();

  XFile? _selectedFile;
  Uint8List? _selectedPreviewBytes;
  bool _isSaving = false;

  Future<void> _pickPhoto() async {
    try {
      final source = PlatformInfo.isAndroid
          ? ImageSource.camera
          : ImageSource.gallery;
      final picked = await _picker.pickImage(source: source, imageQuality: 90);
      if (picked == null || !mounted) return;
      final previewBytes = await picked.readAsBytes();

      setState(() {
        _selectedFile = picked;
        _selectedPreviewBytes = previewBytes;
      });
    } catch (e) {
      if (!mounted) return;
      showErrorToast(context, context.l10n.paymentProofCaptureFailed('$e'));
    }
  }

  Future<void> _save() async {
    final file = _selectedFile;
    if (file == null) {
      showErrorToast(context, context.l10n.paymentProofRequired);
      return;
    }

    setState(() => _isSaving = true);
    try {
      final result = await paymentProofService.saveProof(
        paymentId: widget.paymentId,
        storeId: widget.storeId,
        originalFile: file,
      );
      if (!mounted) return;
      Navigator.of(context).pop(result);
    } catch (e) {
      if (!mounted) return;
      showErrorToast(context, context.l10n.paymentProofSaveFailed('$e'));
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = context.l10n;
    return AlertDialog(
      backgroundColor: PosColors.surface,
      contentPadding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
      title: Row(
        children: [
          const Icon(Icons.photo_camera, color: PosColors.accent, size: 22),
          const SizedBox(width: 8),
          Flexible(
            child: Text(
              l10n.paymentProofTitle,
              style: AppFonts.system(
                fontSize: 24,
                color: PosColors.textPrimary,
                letterSpacing: -0.2,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                l10n.paymentProofDirection(widget.methodLabel.toUpperCase()),
                style: AppFonts.system(
                  color: PosColors.textSecondary,
                  fontSize: 13,
                  height: 1.4,
                ),
              ),
              const SizedBox(height: 14),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: PosColors.canvas,
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(color: PosColors.border),
                ),
                child: _selectedFile == null ? _emptyState() : _previewCard(),
              ),
              const SizedBox(height: 12),
              Text(
                l10n.paymentProofUploadQueueHint,
                style: AppFonts.system(
                  color: PosColors.textSecondary,
                  fontSize: 11,
                ),
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(null),
          child: Text(
            l10n.paymentProofSkipForNow,
            style: AppFonts.system(color: PosColors.textSecondary),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _isSaving ? null : _pickPhoto,
          icon: const Icon(Icons.photo_camera_outlined, size: 16),
          label: Text(
            _selectedFile == null
                ? l10n.paymentProofCapture
                : l10n.paymentProofRetake,
            style: AppFonts.system(fontWeight: FontWeight.w700),
          ),
        ),
        FilledButton.icon(
          onPressed: _isSaving ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: PosColors.accent,
            foregroundColor: Colors.white,
          ),
          icon: _isSaving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 1.8,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.cloud_upload_outlined, size: 16),
          label: Text(
            l10n.paymentProofSaveProof,
            style: AppFonts.system(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  Widget _emptyState() {
    final l10n = context.l10n;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: PosColors.accent.withValues(alpha: 0.14),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.receipt_long,
            color: PosColors.accent,
            size: 34,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          l10n.paymentProofNoPhotoYet,
          style: AppFonts.system(
            color: PosColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          l10n.paymentProofEmptySubtitle,
          textAlign: TextAlign.center,
          style: AppFonts.system(
            color: PosColors.textSecondary,
            fontSize: 12,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _previewCard() {
    final l10n = context.l10n;
    final file = _selectedFile!;
    final previewBytes = _selectedPreviewBytes;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: previewBytes == null
              ? const SizedBox(
                  height: 220,
                  width: double.infinity,
                  child: Center(child: CircularProgressIndicator()),
                )
              : Image.memory(
                  previewBytes,
                  height: 220,
                  width: double.infinity,
                  fit: BoxFit.cover,
                ),
        ),
        const SizedBox(height: 10),
        Text(
          l10n.paymentProofReadyToUpload,
          style: AppFonts.system(
            color: PosColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          _fileLabel(file),
          style: AppFonts.system(color: PosColors.textSecondary, fontSize: 11),
        ),
      ],
    );
  }

  String _fileLabel(XFile file) {
    if (file.name.isNotEmpty) return file.name;
    return file.path.split('/').last;
  }
}
