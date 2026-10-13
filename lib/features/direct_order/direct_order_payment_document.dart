import 'dart:ui' as ui;

import 'package:file_saver/file_saver.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/payments/vietqr_payload.dart';
import '../../core/ui/app_fonts.dart';
import 'direct_order_copy.dart';
import 'direct_order_service.dart';

class DirectOrderPaymentGuideCopy {
  const DirectOrderPaymentGuideCopy(this.language);
  final String language;
  String t(String ko, String vi, String en) => switch (language) {
    'ko' => ko,
    'vi' => vi,
    _ => en,
  };
  String get preview => t(
    '예상 결제금액 · 미확정',
    'Dự kiến thanh toán · chưa chốt',
    'Estimated payment · not finalized',
  );
  String get finalAmount =>
      t('확정 결제금액', 'Tổng thanh toán đã chốt', 'Final payment amount');
  String get unavailable => t(
    '금액을 계산하지 못했습니다. 재시도하세요.',
    'Chưa tính được tiền. Vui lòng thử lại.',
    'Amount unavailable. Please retry.',
  );
  String get quote => t('견적서 PDF', 'PDF báo giá', 'Quote PDF');
  String get sendQuote => t('견적서 PDF 전송', 'Gửi PDF báo giá', 'Send quote PDF');
  String get guide =>
      t('결제 안내서 PDF', 'PDF hướng dẫn thanh toán', 'Payment guide PDF');
  String get png =>
      t('결제 안내 이미지', 'Ảnh hướng dẫn thanh toán', 'Payment guide image');
  String get sendPdf =>
      t('안내서 PDF 전송', 'Gửi PDF thanh toán', 'Send payment PDF');
  String get sendPng =>
      t('안내 이미지 전송', 'Gửi ảnh thanh toán', 'Send payment image');
  String get copyLink => t(
    '고객 주문 링크 복사',
    'Sao chép liên kết đơn khách',
    'Copy customer order link',
  );
  String get sendLink => t(
    '고객에게 주문 링크 전송',
    'Gửi liên kết đơn cho khách',
    'Send customer order link',
  );
  String get linkCopied => t(
    '고객 주문 링크를 복사했습니다.',
    'Đã sao chép liên kết đơn khách.',
    'Customer order link copied.',
  );
  String get sent => t(
    '고객 채팅으로 전송했습니다.',
    'Đã gửi vào trò chuyện khách.',
    'Sent to customer chat.',
  );
  String get saved => t('파일을 저장했습니다.', 'Đã lưu tệp.', 'File saved.');
  String get documentError => t(
    '안내서 처리를 완료하지 못했습니다. 같은 버튼으로 재시도하세요.',
    'Chưa hoàn tất chứng từ. Nhấn lại cùng nút để thử lại.',
    'Document action did not complete. Retry the same button.',
  );
  String get paymentTitle =>
      t('결제 안내서', 'Hướng dẫn thanh toán', 'Payment instructions');
  String get quoteTitle => t('견적서', 'Báo giá', 'Quotation');
  String get outstanding =>
      t('이번 송금 금액', 'Số tiền cần chuyển', 'Amount to transfer');
  String get quantity => t('수량', 'SL', 'Qty');
  String get price => t('단가', 'Đơn giá', 'Unit price');
  String get listed => t('상품 금액', 'Tiền món', 'Listed amount');
  String get version => t('견적 버전', 'Phiên bản báo giá', 'Quote version');
}

class DirectOrderPaymentDocumentService {
  const DirectOrderPaymentDocumentService();

  num _number(Map<String, dynamic> data, String key) {
    final value = data[key];
    if (value is! num || !value.isFinite || value < 0) {
      throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
    }
    return value;
  }

  String paymentQr(Map<String, dynamic> data) {
    final due = _number(data, 'amount_due');
    if (data['include_payment'] != true || due <= 0 || data['bank'] is! Map) {
      throw const DirectOrderException(
        'DIRECT_ORDER_PAYMENT_DOCUMENT_NOT_ALLOWED',
      );
    }
    final bank = Map<String, dynamic>.from(data['bank'] as Map);
    return VietQrPayload.bankTransfer(
      bankBin: bank['bin'].toString(),
      accountNumber: bank['account_number'].toString(),
      amount: due.round(),
      purpose: data['reference_code'].toString(),
    );
  }

  String _money(Object? amount) =>
      '${NumberFormat('#,##0.##', 'vi_VN').format(amount)} VND';
  String _name(Map<String, dynamic> item, String locale) =>
      (item['name_$locale'] ?? item['name_vi'] ?? item['display_name'] ?? '')
          .toString();

  Future<Uint8List> buildPdf(
    Map<String, dynamic> data, {
    required String language,
  }) async {
    final copy = DirectOrderPaymentGuideCopy(language);
    final labels = DirectOrderCopy(language);
    final font = pw.Font.ttf(await rootBundle.load(AppFonts.assetPath));
    final items = (data['items'] as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList(growable: false);
    if (items.isEmpty || items.length > 100) {
      throw const DirectOrderException('DIRECT_ORDER_RESPONSE_INVALID');
    }
    for (final key in [
      'menu_total',
      'menu_vat',
      'service_charge_total',
      'service_charge_vat',
      'final_total',
      'amount_due',
    ]) {
      _number(data, key);
    }
    final payment = data['include_payment'] == true;
    final bank = payment
        ? Map<String, dynamic>.from(data['bank'] as Map)
        : <String, dynamic>{};
    final doc = pw.Document(
      theme: pw.ThemeData.withFont(base: font, bold: font),
    );
    pw.Widget amount(String label, Object? value, {bool strong = false}) =>
        pw.Padding(
          padding: const pw.EdgeInsets.symmetric(vertical: 4),
          child: pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text(label),
              pw.Text(
                _money(value),
                style: pw.TextStyle(fontSize: strong ? 18 : 11),
              ),
            ],
          ),
        );
    doc.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(36),
        maxPages: 20,
        footer: (context) => pw.Align(
          alignment: pw.Alignment.centerRight,
          child: pw.Text(
            '${context.pageNumber} / ${context.pagesCount}',
            style: const pw.TextStyle(fontSize: 8),
          ),
        ),
        build: (_) => [
          pw.Text(
            payment ? copy.paymentTitle : copy.quoteTitle,
            style: const pw.TextStyle(fontSize: 24),
          ),
          pw.SizedBox(height: 8),
          pw.Text(data['store_name'].toString()),
          pw.Text(
            '#${data['reference_code']} · ${copy.version} ${data['quote_version']}',
          ),
          pw.SizedBox(height: 12),
          amount(labels.subtotal, data['menu_total']),
          amount(labels.serviceCharge, data['service_charge_total']),
          amount(
            labels.includedVat,
            _number(data, 'menu_vat') + _number(data, 'service_charge_vat'),
          ),
          amount(labels.finalTotal, data['final_total'], strong: true),
          if (payment) ...[
            amount(copy.outstanding, data['amount_due'], strong: true),
            pw.SizedBox(height: 8),
            pw.Row(
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.BarcodeWidget(
                  barcode: pw.Barcode.qrCode(),
                  data: paymentQr(data),
                  drawText: false,
                  width: 148,
                  height: 148,
                ),
                pw.SizedBox(width: 20),
                pw.Expanded(
                  child: pw.Column(
                    crossAxisAlignment: pw.CrossAxisAlignment.start,
                    children: [
                      pw.Text(labels.transferInstruction),
                      pw.SizedBox(height: 8),
                      pw.Text(bank['label'].toString()),
                      pw.Text(
                        '${labels.accountNumber}: ${bank['account_number']}',
                      ),
                      pw.Text(
                        '${labels.accountHolder}: ${bank['account_holder']}',
                      ),
                      pw.Text(
                        '${labels.transferReference}: ${data['reference_code']}',
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ],
          if (data['delivery_payment_mode'] == 'customer_direct' &&
              data['fulfillment_method'] != 'pickup' &&
              data['fulfillment_type'] != 'pickup') ...[
            pw.SizedBox(height: 8),
            pw.Text(labels.customerPaysDriverHelp),
          ],
          pw.SizedBox(height: 16),
          pw.TableHelper.fromTextArray(
            headers: [
              labels.orderItems,
              copy.quantity,
              copy.price,
              copy.listed,
            ],
            data: [
              for (final item in items)
                [
                  _name(item, language),
                  item['quantity'].toString(),
                  _money(item['unit_price']),
                  _money(item['listed_total']),
                ],
            ],
            cellStyle: const pw.TextStyle(fontSize: 9),
            headerStyle: const pw.TextStyle(fontSize: 9),
            columnWidths: {
              0: const pw.FlexColumnWidth(4),
              1: const pw.FlexColumnWidth(0.7),
              2: const pw.FlexColumnWidth(1.4),
              3: const pw.FlexColumnWidth(1.6),
            },
            cellPadding: const pw.EdgeInsets.all(5),
            border: pw.TableBorder.all(color: PdfColors.grey300, width: 0.5),
          ),
        ],
      ),
    );
    return doc.save();
  }

  /// The image is a complete payment summary. The itemized quote stays in PDF.
  Future<Uint8List> buildPng(
    Map<String, dynamic> data, {
    required String language,
  }) async {
    final copy = DirectOrderPaymentGuideCopy(language),
        labels = DirectOrderCopy(language);
    final bank = Map<String, dynamic>.from(data['bank'] as Map);
    final qr = paymentQr(data);
    final recorder = ui.PictureRecorder();
    final canvas = Canvas(recorder);
    canvas.drawRect(
      const Rect.fromLTWH(0, 0, 1000, 2200),
      Paint()..color = Colors.white,
    );
    var y = 48.0;
    void text(String value, {double size = 28, Color color = Colors.black}) {
      final p = TextPainter(
        text: TextSpan(
          text: value,
          style: TextStyle(
            fontFamily: AppFonts.family,
            fontSize: size,
            color: color,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      );
      p.layout(maxWidth: 904);
      p.paint(canvas, Offset(48, y));
      y += p.height + 18;
      p.dispose();
    }

    text(copy.paymentTitle, size: 42, color: const Color(0xff1454aa));
    text(data['store_name'].toString());
    text(
      '#${data['reference_code']} · ${copy.version} ${data['quote_version']}',
      size: 22,
    );
    text('${labels.subtotal}: ${_money(data['menu_total'])}');
    text('${labels.serviceCharge}: ${_money(data['service_charge_total'])}');
    text(
      '${labels.includedVat}: ${_money(_number(data, 'menu_vat') + _number(data, 'service_charge_vat'))}',
      size: 24,
    );
    text('${labels.finalTotal}: ${_money(data['final_total'])}', size: 34);
    text(
      '${copy.outstanding}: ${_money(data['amount_due'])}',
      size: 36,
      color: const Color(0xff1454aa),
    );
    final painter = QrPainter(
      data: qr,
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
    canvas.translate(330, y + 12);
    painter.paint(canvas, const Size.square(340));
    canvas.restore();
    y += 380;
    text(bank['label'].toString(), size: 25);
    text('${labels.accountNumber}: ${bank['account_number']}', size: 25);
    text('${labels.accountHolder}: ${bank['account_holder']}', size: 25);
    text('${labels.transferReference}: ${data['reference_code']}', size: 25);
    if (data['delivery_payment_mode'] == 'customer_direct' &&
        data['fulfillment_method'] != 'pickup' &&
        data['fulfillment_type'] != 'pickup') {
      text(labels.customerPaysDriverHelp, size: 24);
    }
    if (y > 2100) {
      recorder.endRecording().dispose();
      throw const DirectOrderException('DIRECT_ORDER_DOCUMENT_TOO_LARGE');
    }
    final picture = recorder.endRecording();
    final image = await picture.toImage(1000, (y + 48).ceil());
    picture.dispose();
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    image.dispose();
    if (bytes == null) {
      throw const DirectOrderException('DIRECT_ORDER_TEMPORARILY_UNAVAILABLE');
    }
    return bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes);
  }

  Future<void> save(
    Uint8List bytes, {
    required String filename,
    required bool png,
  }) async {
    await FileSaver.instance.saveFile(
      name: filename,
      bytes: bytes,
      ext: png ? 'png' : 'pdf',
      mimeType: png ? MimeType.png : MimeType.pdf,
    );
  }
}
