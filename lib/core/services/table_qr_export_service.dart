import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:archive/archive.dart';
import 'package:file_saver/file_saver.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:qr_flutter/qr_flutter.dart';

import '../constants/app_constants.dart';
import '../ui/app_fonts.dart';

enum TableQrExportKind { pdf, png }

class TableQrExportProgress {
  const TableQrExportProgress({
    required this.kind,
    required this.completed,
    required this.total,
  });

  final TableQrExportKind kind;
  final int completed;
  final int total;
}

typedef TableQrProgressCallback = void Function(TableQrExportProgress progress);
typedef TableQrPngRenderer = Future<Uint8List> Function(TableQrCardModel card);

class TableQrProgressDialogRunner {
  const TableQrProgressDialogRunner();

  Future<T> run<T>({
    required BuildContext context,
    required ChangeNotifier notifier,
    required WidgetBuilder dialogBuilder,
    required Future<T> Function() operation,
  }) async {
    final ready = Completer<void>();
    BuildContext? dialogContext;
    ModalRoute<void>? dialogRoute;

    final dialogFuture = showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (currentDialogContext) {
        dialogContext = currentDialogContext;
        dialogRoute = ModalRoute.of(currentDialogContext);
        if (!ready.isCompleted) {
          ready.complete();
        }
        return dialogBuilder(currentDialogContext);
      },
    );

    await ready.future;
    try {
      return await operation();
    } finally {
      final currentDialogContext = dialogContext;
      final currentDialogRoute = dialogRoute;
      if (currentDialogContext != null &&
          currentDialogContext.mounted &&
          currentDialogRoute?.isCurrent == true) {
        Navigator.of(currentDialogContext).pop();
      }
      await dialogFuture;
      if (currentDialogRoute != null) {
        await currentDialogRoute.completed;
      }
      notifier.dispose();
    }
  }
}

class TableQrCardModel {
  const TableQrCardModel({
    required this.tokenId,
    required this.tableId,
    required this.tableNumber,
    required this.floorLabel,
    required this.layoutSortOrder,
    required this.storeName,
    required this.token,
    required this.orderUrl,
  });

  static const scanCopy = <String>[
    '휴대폰 카메라로 스캔해 주문하세요',
    'Scan with your phone to order',
    'Quét bằng điện thoại để gọi món',
  ];

  final String tokenId;
  final String tableId;
  final String tableNumber;
  final String floorLabel;
  final int layoutSortOrder;
  final String storeName;
  final String token;
  final String orderUrl;

  factory TableQrCardModel.fromRpcRow(
    Map<String, dynamic> row, {
    String? publicBaseUrl,
  }) {
    String requiredText(String field) {
      final value = row[field]?.toString() ?? '';
      if (value.isEmpty) {
        throw FormatException('TABLE_QR_FIELD_REQUIRED:$field');
      }
      return value;
    }

    final token = requiredText('token');
    final baseUri = Uri.tryParse(publicBaseUrl ?? AppConstants.posPublicUrl);
    if (baseUri == null || baseUri.scheme != 'https' || !baseUri.hasAuthority) {
      throw const FormatException('TABLE_QR_PUBLIC_URL_INVALID');
    }
    final orderUri = Uri.parse(
      baseUri.origin,
    ).replace(path: '/', fragment: '/qr/${Uri.encodeComponent(token)}');

    return TableQrCardModel(
      tokenId: requiredText('token_id'),
      tableId: requiredText('table_id'),
      tableNumber: requiredText('table_number'),
      floorLabel: requiredText('floor_label'),
      layoutSortOrder: switch (row['layout_sort_order']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 0,
        _ => 0,
      },
      storeName: requiredText('store_name'),
      token: token,
      orderUrl: orderUri.toString(),
    );
  }
}

class TableQrExportService {
  const TableQrExportService({TableQrPngRenderer? pngRenderer})
    : _pngRenderer = pngRenderer;

  final TableQrPngRenderer? _pngRenderer;

  List<TableQrCardModel> cardsFromRpcRows(
    List<Map<String, dynamic>> rows, {
    String? publicBaseUrl,
  }) {
    final cards = rows
        .map(
          (row) =>
              TableQrCardModel.fromRpcRow(row, publicBaseUrl: publicBaseUrl),
        )
        .toList();
    cards.sort((left, right) {
      final orderCompare = left.layoutSortOrder.compareTo(
        right.layoutSortOrder,
      );
      if (orderCompare != 0) return orderCompare;
      final numberCompare = left.tableNumber.compareTo(right.tableNumber);
      if (numberCompare != 0) return numberCompare;
      return left.tableId.compareTo(right.tableId);
    });
    return List<TableQrCardModel>.unmodifiable(cards);
  }

  Future<Uint8List> buildPdf(
    List<TableQrCardModel> cards, {
    TableQrProgressCallback? onProgress,
  }) async {
    _requireCards(cards);
    final supportsUnicode = !kIsWeb;
    final pw.Document document;
    if (supportsUnicode) {
      final fontData = await rootBundle.load(AppFonts.assetPath);
      final font = pw.Font.ttf(fontData);
      document = pw.Document(
        theme: pw.ThemeData.withFont(base: font, bold: font),
      );
    } else {
      // Embedding the 6.7 MB Unicode font makes browser PDF generation stall
      // before FileSaver can start the download. QR labels contain only the
      // ASCII fallback below on web, so the built-in PDF font is sufficient.
      document = pw.Document();
    }

    for (var index = 0; index < cards.length; index++) {
      final card = cards[index];
      document.addPage(
        pw.Page(
          pageFormat: PdfPageFormat.a6,
          margin: const pw.EdgeInsets.all(18),
          build: (_) => _buildPdfCard(card, supportsUnicode: supportsUnicode),
        ),
      );
      onProgress?.call(
        TableQrExportProgress(
          kind: TableQrExportKind.pdf,
          completed: index + 1,
          total: cards.length,
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }
    return document.save();
  }

  Future<Uint8List> buildPng(TableQrCardModel card) async {
    final renderer = _pngRenderer;
    if (renderer != null) {
      return renderer(card);
    }
    const width = 620;
    const height = 874;
    const qrSize = 800.0;
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.scale(0.5);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 1240, 1748),
      Paint()..color = Colors.white,
    );
    canvas.drawRect(
      const Rect.fromLTWH(36, 36, 1168, 1676),
      Paint()
        ..color = const Color(0xFF111827)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5,
    );

    _drawCentered(
      canvas,
      card.storeName,
      top: 92,
      fontSize: 50,
      bold: true,
      fitSingleLine: true,
    );
    _drawCentered(canvas, 'TABLE', top: 190, fontSize: 34);
    _drawCentered(
      canvas,
      card.tableNumber,
      top: 238,
      fontSize: 120,
      bold: true,
      fitSingleLine: true,
    );
    _drawCentered(
      canvas,
      card.floorLabel,
      top: 390,
      fontSize: 42,
      bold: true,
      fitSingleLine: true,
    );

    // A 100 logical-pixel quiet zone surrounds the 800-pixel QR. After the
    // 0.5 A6 raster scale this remains wider than four modules for this URL.
    const qrOuter = Rect.fromLTWH(120, 425, 1000, 1000);
    canvas.drawRect(qrOuter, Paint()..color = Colors.white);
    final qrPainter = QrPainter(
      data: card.orderUrl,
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
    canvas.translate(220, 525);
    qrPainter.paint(canvas, const Size.square(qrSize));
    canvas.restore();

    for (var index = 0; index < TableQrCardModel.scanCopy.length; index++) {
      _drawCentered(
        canvas,
        TableQrCardModel.scanCopy[index],
        top: 1460 + (index * 66),
        fontSize: index == 0 ? 32 : 30,
        bold: index == 0,
      );
    }

    final picture = recorder.endRecording();
    final image = await picture.toImage(width, height);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    picture.dispose();
    if (data == null) {
      throw StateError('TABLE_QR_PNG_RENDER_FAILED');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  Future<Uint8List> buildPngZip(
    List<TableQrCardModel> cards, {
    TableQrProgressCallback? onProgress,
  }) async {
    _requireCards(cards);
    final archive = Archive();
    for (var index = 0; index < cards.length; index++) {
      final card = cards[index];
      final bytes = await buildPng(card);
      final fileName = _pngFileName(card);
      archive.addFile(ArchiveFile(fileName, bytes.length, bytes));
      onProgress?.call(
        TableQrExportProgress(
          kind: TableQrExportKind.png,
          completed: index + 1,
          total: cards.length,
        ),
      );
      await Future<void>.delayed(Duration.zero);
    }
    final encoded = ZipEncoder().encode(archive);
    if (encoded == null) {
      throw StateError('TABLE_QR_ZIP_ENCODE_FAILED');
    }
    return Uint8List.fromList(encoded);
  }

  Future<void> savePdf(
    List<TableQrCardModel> cards, {
    TableQrProgressCallback? onProgress,
  }) async {
    final bytes = await buildPdf(cards, onProgress: onProgress);
    await FileSaver.instance.saveFile(
      name: 'table_qr_${_sanitizeFileName(cards.first.storeName)}',
      bytes: bytes,
      ext: 'pdf',
      mimeType: MimeType.pdf,
    );
  }

  Future<void> savePng(TableQrCardModel card) async {
    final bytes = await buildPng(card);
    await FileSaver.instance.saveFile(
      name: _pngFileName(card).replaceFirst(RegExp(r'\.png$'), ''),
      bytes: bytes,
      ext: 'png',
      mimeType: MimeType.png,
    );
  }

  Future<void> savePngZip(
    List<TableQrCardModel> cards, {
    TableQrProgressCallback? onProgress,
  }) async {
    final bytes = await buildPngZip(cards, onProgress: onProgress);
    await FileSaver.instance.saveFile(
      name: 'table_qr_png_${_sanitizeFileName(cards.first.storeName)}',
      bytes: bytes,
      ext: 'zip',
      mimeType: MimeType.zip,
    );
  }

  pw.Widget _buildPdfCard(
    TableQrCardModel card, {
    required bool supportsUnicode,
  }) {
    final storeName = supportsUnicode
        ? card.storeName
        : _toPdfAscii(card.storeName, fallback: 'GLOBOS POS');
    final tableNumber = supportsUnicode
        ? card.tableNumber
        : _toPdfAscii(card.tableNumber, fallback: 'TABLE');
    final floorLabel = supportsUnicode
        ? card.floorLabel
        : _toPdfAscii(card.floorLabel, fallback: 'FLOOR');
    final scanCopy = supportsUnicode
        ? TableQrCardModel.scanCopy
        : const <String>[
            'SCAN WITH YOUR PHONE TO ORDER',
            'QUET MA QR DE GOI MON',
          ];
    return pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.SizedBox(
          height: 22,
          child: pw.FittedBox(
            fit: pw.BoxFit.scaleDown,
            child: pw.Text(
              storeName,
              style: pw.TextStyle(fontSize: 17, fontWeight: pw.FontWeight.bold),
            ),
          ),
        ),
        pw.SizedBox(height: 5),
        pw.Text(
          'TABLE',
          textAlign: pw.TextAlign.center,
          style: const pw.TextStyle(fontSize: 10),
        ),
        pw.SizedBox(
          height: 45,
          child: pw.FittedBox(
            fit: pw.BoxFit.scaleDown,
            child: pw.Text(
              tableNumber,
              style: pw.TextStyle(fontSize: 37, fontWeight: pw.FontWeight.bold),
            ),
          ),
        ),
        pw.SizedBox(
          height: 15,
          child: pw.FittedBox(
            fit: pw.BoxFit.scaleDown,
            child: pw.Text(
              floorLabel,
              style: pw.TextStyle(fontSize: 12, fontWeight: pw.FontWeight.bold),
            ),
          ),
        ),
        pw.SizedBox(height: 8),
        pw.Center(
          child: pw.Container(
            color: PdfColors.white,
            // Keep a vector quiet zone outside the QR modules.
            padding: const pw.EdgeInsets.all(20),
            child: pw.BarcodeWidget(
              barcode: pw.Barcode.qrCode(),
              data: card.orderUrl,
              width: 190,
              height: 190,
              drawText: false,
            ),
          ),
        ),
        pw.Spacer(),
        for (final copy in scanCopy)
          pw.Padding(
            padding: const pw.EdgeInsets.only(top: 2),
            child: pw.Text(
              copy,
              textAlign: pw.TextAlign.center,
              maxLines: 1,
              style: const pw.TextStyle(fontSize: 8.5),
            ),
          ),
      ],
    );
  }

  static void _drawCentered(
    Canvas canvas,
    String text, {
    required double top,
    required double fontSize,
    bool bold = false,
    int maxLines = 2,
    bool fitSingleLine = false,
  }) {
    TextPainter buildPainter(double resolvedSize) => TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(
          color: Colors.black,
          fontFamily: AppFonts.family,
          fontSize: resolvedSize,
          fontWeight: bold ? FontWeight.w800 : FontWeight.w500,
        ),
      ),
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
      maxLines: fitSingleLine ? 1 : maxLines,
      ellipsis: fitSingleLine ? null : '…',
    );

    var painter = buildPainter(fontSize)..layout();
    if (fitSingleLine && painter.width > 1080) {
      painter = buildPainter(fontSize * 1080 / painter.width)..layout();
    } else if (!fitSingleLine) {
      painter.layout(maxWidth: 1080);
    }
    painter.paint(canvas, Offset((1240 - painter.width) / 2, top));
  }

  static String _pngFileName(TableQrCardModel card) {
    final shortId = card.tableId.replaceAll('-', '').substring(0, 8);
    return 'table_qr_${_sanitizeFileName(card.tableNumber)}_$shortId.png';
  }

  static String _sanitizeFileName(String value) {
    final sanitized = value
        .trim()
        .replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '_')
        .replaceAll(RegExp(r'\s+'), '_')
        .replaceAll(RegExp(r'_+'), '_');
    return sanitized.isEmpty ? 'table' : sanitized;
  }

  static String _toPdfAscii(String value, {required String fallback}) {
    const replacements = <String, String>{
      'àáạảãâầấậẩẫăằắặẳẵ': 'a',
      'ÀÁẠẢÃÂẦẤẬẨẪĂẰẮẶẲẴ': 'A',
      'èéẹẻẽêềếệểễ': 'e',
      'ÈÉẸẺẼÊỀẾỆỂỄ': 'E',
      'ìíịỉĩ': 'i',
      'ÌÍỊỈĨ': 'I',
      'òóọỏõôồốộổỗơờớợởỡ': 'o',
      'ÒÓỌỎÕÔỒỐỘỔỖƠỜỚỢỞỠ': 'O',
      'ùúụủũưừứựửữ': 'u',
      'ÙÚỤỦŨƯỪỨỰỬỮ': 'U',
      'ỳýỵỷỹ': 'y',
      'ỲÝỴỶỸ': 'Y',
      'đ': 'd',
      'Đ': 'D',
    };
    final characterMap = <String, String>{
      for (final entry in replacements.entries)
        for (final character in entry.key.split('')) character: entry.value,
    };
    final result = StringBuffer();
    for (final rune in value.runes) {
      final character = String.fromCharCode(rune);
      final replacement = characterMap[character];
      if (replacement != null) {
        result.write(replacement);
      } else if (rune >= 0x20 && rune <= 0x7E) {
        result.write(character);
      }
    }
    final normalized = result.toString().trim();
    return normalized.isEmpty ? fallback : normalized;
  }

  static void _requireCards(List<TableQrCardModel> cards) {
    if (cards.isEmpty) {
      throw StateError('TABLE_QR_EXPORT_EMPTY');
    }
  }
}

const tableQrExportService = TableQrExportService();
const tableQrProgressDialogRunner = TableQrProgressDialogRunner();
