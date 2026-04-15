import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:image_picker/image_picker.dart';

import '../../core/layout/platform_info.dart';
import '../../core/services/payment_proof_service.dart';
import '../../main.dart';
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

  File? _selectedFile;
  bool _isSaving = false;

  Future<void> _pickPhoto() async {
    try {
      final source = PlatformInfo.isAndroid
          ? ImageSource.camera
          : ImageSource.gallery;
      final picked = await _picker.pickImage(source: source, imageQuality: 90);
      if (picked == null || !mounted) return;

      setState(() => _selectedFile = File(picked.path));
    } catch (e) {
      if (!mounted) return;
      showErrorToast(context, 'Proof photo capture failed: $e');
    }
  }

  Future<void> _save() async {
    final file = _selectedFile;
    if (file == null) {
      showErrorToast(context, 'Capture or choose a proof photo first.');
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
      showErrorToast(context, 'Proof save failed: $e');
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppColors.surface1,
      contentPadding: const EdgeInsets.fromLTRB(24, 18, 24, 0),
      title: Row(
        children: [
          const Icon(Icons.photo_camera, color: AppColors.amber500, size: 22),
          const SizedBox(width: 8),
          Text(
            'Payment Proof',
            style: GoogleFonts.bebasNeue(
              color: AppColors.textPrimary,
              fontSize: 28,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Direction: Operational — capture a quick proof photo for ${widget.methodLabel.toUpperCase()} settlement before you move on.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(14),
              decoration: BoxDecoration(
                color: AppColors.surface0,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: AppColors.surface2),
              ),
              child: _selectedFile == null ? _emptyState() : _previewCard(),
            ),
            const SizedBox(height: 12),
            Text(
              'If upload fails, we will queue the photo locally and retry on the next cashier session.',
              style: GoogleFonts.notoSansKr(
                color: AppColors.textSecondary,
                fontSize: 11,
              ),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isSaving ? null : () => Navigator.of(context).pop(null),
          child: Text(
            'Skip for now',
            style: GoogleFonts.notoSansKr(color: AppColors.textSecondary),
          ),
        ),
        OutlinedButton.icon(
          onPressed: _isSaving ? null : _pickPhoto,
          icon: const Icon(Icons.photo_camera_outlined, size: 16),
          label: Text(
            _selectedFile == null ? 'Capture' : 'Retake',
            style: GoogleFonts.notoSansKr(fontWeight: FontWeight.w700),
          ),
        ),
        FilledButton.icon(
          onPressed: _isSaving ? null : _save,
          style: FilledButton.styleFrom(
            backgroundColor: AppColors.amber500,
            foregroundColor: AppColors.surface0,
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
            'Save Proof',
            style: GoogleFonts.notoSansKr(fontWeight: FontWeight.w700),
          ),
        ),
      ],
    );
  }

  Widget _emptyState() {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppColors.amber500.withValues(alpha: 0.14),
            shape: BoxShape.circle,
          ),
          child: const Icon(
            Icons.receipt_long,
            color: AppColors.amber500,
            size: 34,
          ),
        ),
        const SizedBox(height: 12),
        Text(
          'No proof photo yet',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontSize: 15,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Capture the terminal slip, QR confirmation, or transfer evidence.',
          textAlign: TextAlign.center,
          style: GoogleFonts.notoSansKr(
            color: AppColors.textSecondary,
            fontSize: 12,
            height: 1.4,
          ),
        ),
      ],
    );
  }

  Widget _previewCard() {
    final file = _selectedFile!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Image.file(
            file,
            height: 220,
            width: double.infinity,
            fit: BoxFit.cover,
          ),
        ),
        const SizedBox(height: 10),
        Text(
          'Ready to upload',
          style: GoogleFonts.notoSansKr(
            color: AppColors.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          file.path.split('/').last,
          style: GoogleFonts.firaCode(
            color: AppColors.textSecondary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}
