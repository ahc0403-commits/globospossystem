import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'direct_order_png_share_stub.dart'
    if (dart.library.js_interop) 'direct_order_png_share_web.dart';
import '../../core/payments/vietqr_payload.dart';
import 'direct_order_copy.dart';
import 'direct_order_models.dart';

/// On-demand export of the exact payment QR; no bank or server request is made.
class DirectOrderPaymentQrActions extends StatefulWidget {
  const DirectOrderPaymentQrActions({
    super.key,
    required this.bank,
    required this.amount,
    required this.reference,
  });
  final DirectOrderBank bank;
  final int amount;
  final String reference;
  @override
  State<DirectOrderPaymentQrActions> createState() => _PaymentQrActionsState();
}

class _PaymentQrActionsState extends State<DirectOrderPaymentQrActions> {
  bool busy = false;
  Future<void> export(bool share) async {
    if (busy) return;
    setState(() => busy = true);
    try {
      final painter = QrPainter(
        data: VietQrPayload.bankTransfer(
          bankBin: widget.bank.bin,
          accountNumber: widget.bank.accountNumber,
          amount: widget.amount,
          purpose: widget.reference,
        ),
        version: QrVersions.auto,
        gapless: true,
      );
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 1100, 1100),
        Paint()..color = Colors.white,
      );
      canvas.translate(50, 50);
      painter.paint(canvas, const Size.square(1000));
      final picture = recorder.endRecording();
      final image = await picture.toImage(1100, 1100);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      picture.dispose();
      if (data == null) throw StateError('QR_RENDER_FAILED');
      final png = Uint8List.sublistView(data);
      final name =
          'payment_qr_${widget.reference.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_')}';
      if (share) {
        if (!await sharePaymentQrPng(png, '$name.png')) {
          await FileSaver.instance.saveFile(
            name: name,
            bytes: png,
            ext: 'png',
            mimeType: MimeType.png,
          );
        }
      } else {
        await FileSaver.instance.saveFile(
          name: name,
          bytes: png,
          ext: 'png',
          mimeType: MimeType.png,
        );
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              DirectOrderCopy(
                Localizations.localeOf(context).languageCode,
              ).bankAppFallback,
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final copy = DirectOrderCopy(Localizations.localeOf(context).languageCode);
    return Wrap(
      spacing: 8,
      children: [
        TextButton.icon(
          key: const Key('direct_save_payment_qr'),
          onPressed: busy ? null : () => export(false),
          icon: const Icon(Icons.download),
          label: Text(copy.savePaymentQr),
        ),
        TextButton.icon(
          key: const Key('direct_share_payment_qr'),
          onPressed: busy ? null : () => export(true),
          icon: const Icon(Icons.share),
          label: Text(copy.sharePaymentQr),
        ),
      ],
    );
  }
}
