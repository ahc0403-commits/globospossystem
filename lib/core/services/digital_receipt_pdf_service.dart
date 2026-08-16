import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../features/digital_receipt/digital_receipt_model.dart';

const digitalReceiptFooterThanksVi = 'Cảm ơn quý khách!';
const digitalReceiptFooterNoticeVi =
    'Biên lai này dùng làm chứng từ thanh toán, không phải hóa đơn đỏ.';
const digitalReceiptPdfPageFormat = PdfPageFormat.roll80;
const digitalReceiptPrintPageFormat = PdfPageFormat(
  80 * PdfPageFormat.mm,
  297 * PdfPageFormat.mm,
);

String digitalReceiptPaymentMethodVi(String method) {
  return switch (method.trim().toUpperCase()) {
    'CASH' => 'Tiền mặt',
    'CREDITCARD' || 'CARD' => 'Thẻ tín dụng',
    'ATM' => 'Thẻ ATM',
    'BANKTRANSFER' || 'BANK_TRANSFER' => 'Chuyển khoản',
    'MOMO' => 'Ví MoMo',
    'ZALOPAY' => 'Ví ZaloPay',
    'VNPAY' => 'VNPay',
    'SHOPEEPAY' => 'Ví ShopeePay',
    'VOUCHER' => 'Phiếu thanh toán',
    'CREDITSALE' => 'Bán chịu',
    'SPLIT' => 'Thanh toán kết hợp',
    'SERVICE' => 'Dịch vụ',
    _ => 'Khác',
  };
}

String digitalReceiptItemLabelVi(String label) {
  final value = label.trim();
  if (value.isEmpty || value.toUpperCase() == 'ITEM') return 'Món';
  if (RegExp(r'[\uac00-\ud7af]').hasMatch(value)) return 'Món';
  return value;
}

class DigitalReceiptPdfService {
  const DigitalReceiptPdfService();

  Future<Uint8List> build(DigitalReceipt receipt) async {
    final fontData = await rootBundle.load(
      'assets/fonts/PretendardVariable.ttf',
    );
    final font = pw.Font.ttf(fontData);
    final document = pw.Document();
    final currency = NumberFormat('#,###', 'vi_VN');
    final timestamp = DateFormat(
      'dd/MM/yyyy · HH:mm',
    ).format(receipt.paidAt.toLocal());
    final billableItems = receipt.items
        .where((item) => !item.isServiceItem)
        .toList(growable: false);

    document.addPage(
      pw.Page(
        pageFormat: digitalReceiptPdfPageFormat,
        margin: const pw.EdgeInsets.fromLTRB(
          5 * PdfPageFormat.mm,
          5 * PdfPageFormat.mm,
          5 * PdfPageFormat.mm,
          7 * PdfPageFormat.mm,
        ),
        theme: pw.ThemeData.withFont(base: font, bold: font),
        build: (_) => pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.stretch,
          mainAxisSize: pw.MainAxisSize.min,
          children: [
            _storeHeader(receipt),
            pw.SizedBox(height: 12),
            _receiptTitle(),
            pw.SizedBox(height: 10),
            _detailLine('Số phiếu', receipt.receiptNumber, boldValue: true),
            _detailLine('Ngày / Giờ', timestamp),
            _detailLine('Thu ngân', receipt.cashierCode),
            _detailLine('Bàn', receipt.tableNumber, boldValue: true),
            _dashedDivider(height: 15),
            _sectionHeader('MÓN', 'THÀNH TIỀN'),
            pw.SizedBox(height: 2),
            for (var index = 0; index < billableItems.length; index++) ...[
              _itemLine(billableItems[index], currency),
              if (index != billableItems.length - 1)
                _dashedDivider(height: 9, color: PdfColors.grey400),
            ],
            _dashedDivider(height: 15),
            _amountLine('Tạm tính', receipt.subtotalAmount, currency),
            if (receipt.serviceChargeAmount > 0)
              _amountLine('Phí dịch vụ', receipt.serviceChargeAmount, currency),
            if (receipt.discountAmount > 0)
              _amountLine('Giảm giá', -receipt.discountAmount, currency),
            _amountLine('VAT (đã gồm)', receipt.vatAmount, currency),
            pw.SizedBox(height: 8),
            _totalBox(receipt, currency),
            pw.SizedBox(height: 14),
            _sectionHeader('THANH TOÁN', ''),
            pw.SizedBox(height: 5),
            if (receipt.payments.isEmpty)
              _detailLine(
                'Phương thức',
                digitalReceiptPaymentMethodVi(receipt.paymentMethod),
              )
            else
              for (final payment in receipt.payments)
                _detailLine(
                  digitalReceiptPaymentMethodVi(payment.method),
                  '${currency.format(payment.amount)} VND',
                  boldValue: true,
                ),
            _detailLine(
              'Khách trả',
              '${currency.format(receipt.receivedAmount)} VND',
            ),
            _detailLine(
              'Tiền thừa',
              '${currency.format(receipt.changeAmount)} VND',
            ),
            if (receipt.isService) ...[
              _dashedDivider(height: 14),
              pw.Text(
                'PHỤC VỤ NỘI BỘ · KHÔNG TÍNH DOANH THU',
                textAlign: pw.TextAlign.center,
                style: pw.TextStyle(
                  fontSize: 7.5,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ],
            _dashedDivider(height: 20),
            pw.Text(
              digitalReceiptFooterThanksVi,
              textAlign: pw.TextAlign.center,
              style: pw.TextStyle(fontSize: 11, fontWeight: pw.FontWeight.bold),
            ),
            pw.SizedBox(height: 5),
            pw.Text(
              digitalReceiptFooterNoticeVi,
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey700),
            ),
            pw.SizedBox(height: 10),
            pw.Text(
              '•  •  •',
              textAlign: pw.TextAlign.center,
              style: const pw.TextStyle(fontSize: 7, color: PdfColors.grey600),
            ),
          ],
        ),
      ),
    );
    return document.save();
  }

  Future<void> saveOrShare(DigitalReceipt receipt) async {
    await Printing.sharePdf(
      bytes: await build(receipt),
      filename: '${receipt.receiptNumber}.pdf',
    );
  }

  Future<void> printReceipt(DigitalReceipt receipt) async {
    final bytes = await build(receipt);
    await Printing.layoutPdf(
      name: receipt.receiptNumber,
      format: digitalReceiptPrintPageFormat,
      dynamicLayout: false,
      onLayout: (_) async => bytes,
    );
  }

  pw.Widget _storeHeader(DigitalReceipt receipt) => pw.Column(
    crossAxisAlignment: pw.CrossAxisAlignment.stretch,
    children: [
      pw.Text(
        receipt.restaurantName.toUpperCase(),
        textAlign: pw.TextAlign.center,
        style: pw.TextStyle(
          fontSize: 16,
          fontWeight: pw.FontWeight.bold,
          letterSpacing: 0.4,
        ),
      ),
      pw.SizedBox(height: 4),
      if (receipt.legalName != null)
        _centeredStoreLine(receipt.legalName!, bold: true),
      if (receipt.taxCode != null)
        _centeredStoreLine('MST: ${receipt.taxCode}'),
      for (final line in receipt.addressLines) _centeredStoreLine(line),
    ],
  );

  pw.Widget _centeredStoreLine(String value, {bool bold = false}) => pw.Padding(
    padding: const pw.EdgeInsets.only(bottom: 1.5),
    child: pw.Text(
      value,
      textAlign: pw.TextAlign.center,
      style: pw.TextStyle(
        fontSize: 7.4,
        color: PdfColors.grey800,
        fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    ),
  );

  pw.Widget _receiptTitle() => pw.Container(
    padding: const pw.EdgeInsets.symmetric(vertical: 7),
    decoration: const pw.BoxDecoration(
      border: pw.Border(
        top: pw.BorderSide(width: 1.2),
        bottom: pw.BorderSide(width: 1.2),
      ),
    ),
    child: pw.Text(
      'PHIẾU THANH TOÁN',
      textAlign: pw.TextAlign.center,
      style: pw.TextStyle(
        fontSize: 11.5,
        fontWeight: pw.FontWeight.bold,
        letterSpacing: 0.8,
      ),
    ),
  );

  pw.Widget _sectionHeader(String label, String trailing) => pw.Row(
    children: [
      pw.Expanded(
        child: pw.Text(
          label,
          style: pw.TextStyle(
            fontSize: 7,
            color: PdfColors.grey700,
            fontWeight: pw.FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
      ),
      if (trailing.isNotEmpty)
        pw.Text(
          trailing,
          style: pw.TextStyle(
            fontSize: 7,
            color: PdfColors.grey700,
            fontWeight: pw.FontWeight.bold,
            letterSpacing: 0.5,
          ),
        ),
    ],
  );

  pw.Widget _itemLine(
    DigitalReceiptItem item,
    NumberFormat currency,
  ) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 5),
    child: pw.Column(
      crossAxisAlignment: pw.CrossAxisAlignment.stretch,
      children: [
        pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          children: [
            pw.Expanded(
              child: pw.Text(
                digitalReceiptItemLabelVi(item.label),
                style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.SizedBox(width: 6),
            pw.Text(
              currency.format(item.lineTotal),
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            ),
          ],
        ),
        pw.SizedBox(height: 2),
        pw.Text(
          '${item.quantity} × ${currency.format(item.unitPrice)} VND',
          style: const pw.TextStyle(fontSize: 7.4, color: PdfColors.grey700),
        ),
      ],
    ),
  );

  pw.Widget _detailLine(
    String label,
    String value, {
    bool boldValue = false,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 2.1),
    child: pw.Row(
      crossAxisAlignment: pw.CrossAxisAlignment.start,
      children: [
        pw.SizedBox(
          width: 54,
          child: pw.Text(
            label,
            style: const pw.TextStyle(fontSize: 7.8, color: PdfColors.grey700),
          ),
        ),
        pw.Expanded(
          child: pw.Text(
            value,
            textAlign: pw.TextAlign.right,
            style: pw.TextStyle(
              fontSize: 7.8,
              fontWeight: boldValue ? pw.FontWeight.bold : pw.FontWeight.normal,
            ),
          ),
        ),
      ],
    ),
  );

  pw.Widget _amountLine(String label, double amount, NumberFormat currency) =>
      pw.Padding(
        padding: const pw.EdgeInsets.symmetric(vertical: 2.2),
        child: pw.Row(
          children: [
            pw.Expanded(
              child: pw.Text(label, style: const pw.TextStyle(fontSize: 8.2)),
            ),
            pw.Text(
              '${currency.format(amount)} VND',
              style: const pw.TextStyle(fontSize: 8.2),
            ),
          ],
        ),
      );

  pw.Widget _totalBox(DigitalReceipt receipt, NumberFormat currency) =>
      pw.Container(
        padding: const pw.EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        decoration: pw.BoxDecoration(
          color: PdfColors.grey100,
          border: pw.Border.all(width: 1.2),
        ),
        child: pw.Row(
          crossAxisAlignment: pw.CrossAxisAlignment.end,
          children: [
            pw.Expanded(
              child: pw.Text(
                receipt.isService ? 'DỊCH VỤ' : 'TỔNG CỘNG',
                style: pw.TextStyle(
                  fontSize: 9,
                  fontWeight: pw.FontWeight.bold,
                ),
              ),
            ),
            pw.Text(
              '${currency.format(receipt.totalAmount)} VND',
              style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold),
            ),
          ],
        ),
      );

  pw.Widget _dashedDivider({
    double height = 12,
    PdfColor color = PdfColors.grey700,
  }) => pw.Divider(
    height: height,
    thickness: 0.6,
    color: color,
    borderStyle: pw.BorderStyle.dashed,
  );
}

const digitalReceiptPdfService = DigitalReceiptPdfService();
