import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:qr_flutter/qr_flutter.dart';

typedef DirectOrderQrRenderer = Future<Uint8List> Function(String url);
typedef DirectOrderQrSaver =
    Future<void> Function(String name, Uint8List bytes);
typedef DirectOrderQrPrinter =
    Future<void> Function(String name, Uint8List pngBytes, String url);

class DirectOrderQrExportService {
  const DirectOrderQrExportService({
    DirectOrderQrRenderer? renderer,
    DirectOrderQrSaver? saver,
    DirectOrderQrPrinter? printer,
  }) : _renderer = renderer,
       _saver = saver,
       _printer = printer;

  final DirectOrderQrRenderer? _renderer;
  final DirectOrderQrSaver? _saver;
  final DirectOrderQrPrinter? _printer;

  Future<Uint8List> buildPng(String url) async {
    _requirePublicOrderUrl(url);
    final renderer = _renderer;
    if (renderer != null) return renderer(url);

    const imageSize = 1200;
    const qrSize = 960.0;
    const inset = (imageSize - qrSize) / 2;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      Rect.fromLTWH(0, 0, imageSize.toDouble(), imageSize.toDouble()),
      Paint()..color = Colors.white,
    );
    final painter = QrPainter(
      data: url,
      version: QrVersions.auto,
      gapless: true,
      eyeStyle: const QrEyeStyle(
        eyeShape: QrEyeShape.square,
        color: Colors.black,
      ),
      dataModuleStyle: const QrDataModuleStyle(
        dataModuleShape: QrDataModuleShape.square,
        color: Colors.black,
      ),
    );
    canvas.save();
    canvas.translate(inset, inset);
    painter.paint(canvas, const Size.square(qrSize));
    canvas.restore();

    final picture = recorder.endRecording();
    final image = await picture.toImage(imageSize, imageSize);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (data == null) throw StateError('DIRECT_ORDER_QR_RENDER_FAILED');
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<void> savePng({required String slug, required String url}) async {
    final bytes = await buildPng(url);
    final name = 'external_order_qr_${_safeSlug(slug)}';
    final saver = _saver;
    if (saver != null) {
      await saver(name, bytes);
      return;
    }
    await FileSaver.instance.saveFile(
      name: name,
      bytes: bytes,
      ext: 'png',
      mimeType: MimeType.png,
    );
  }

  Future<void> printQr({required String slug, required String url}) async {
    final bytes = await buildPng(url);
    final name = 'external_order_qr_${_safeSlug(slug)}';
    final printer = _printer;
    if (printer != null) {
      await printer(name, bytes, url);
      return;
    }

    final document = pw.Document();
    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat.a5,
        margin: const pw.EdgeInsets.all(30),
        build: (_) => pw.Column(
          mainAxisAlignment: pw.MainAxisAlignment.center,
          crossAxisAlignment: pw.CrossAxisAlignment.center,
          children: [
            pw.Text(
              'External Order',
              style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 20),
            pw.Image(pw.MemoryImage(bytes), width: 260, height: 260),
            pw.SizedBox(height: 16),
            pw.Text(url, textAlign: pw.TextAlign.center),
          ],
        ),
      ),
    );
    final pdfBytes = await document.save();
    await Printing.layoutPdf(
      name: name,
      format: PdfPageFormat.a5,
      dynamicLayout: false,
      onLayout: (_) async => pdfBytes,
    );
  }

  void _requirePublicOrderUrl(String value) {
    final uri = Uri.tryParse(value);
    final route = uri == null
        ? ''
        : (uri.fragment.startsWith('/order/') ? uri.fragment : uri.path);
    if (uri == null ||
        uri.scheme != 'https' ||
        uri.host.isEmpty ||
        !RegExp(r'^/order/[a-z0-9][a-z0-9-]{2,62}$').hasMatch(route)) {
      throw const FormatException('DIRECT_ORDER_QR_URL_INVALID');
    }
  }

  String _safeSlug(String value) {
    final normalized = value.trim().toLowerCase().replaceAll(
      RegExp('[^a-z0-9-]+'),
      '-',
    );
    if (normalized.isEmpty) {
      throw const FormatException('DIRECT_ORDER_QR_SLUG_INVALID');
    }
    return normalized;
  }
}

const directOrderQrExportService = DirectOrderQrExportService();
