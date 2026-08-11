import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../features/digital_receipt/digital_receipt_model.dart';

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
      'dd/MM/yyyy HH:mm',
    ).format(receipt.paidAt.toLocal());

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        theme: pw.ThemeData.withFont(base: font, bold: font),
        build: (_) => [
          pw.Text(
            receipt.restaurantName,
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold),
          ),
          if (receipt.legalName != null)
            pw.Text(receipt.legalName!, textAlign: pw.TextAlign.center),
          if (receipt.taxCode != null)
            pw.Text('MST: ${receipt.taxCode}', textAlign: pw.TextAlign.center),
          for (final line in receipt.addressLines)
            pw.Text(line, textAlign: pw.TextAlign.center),
          pw.SizedBox(height: 20),
          pw.Divider(),
          pw.Text(
            'PHIẾU THANH TOÁN',
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(fontSize: 18, fontWeight: pw.FontWeight.bold),
          ),
          pw.Divider(),
          _line('Số phiếu', receipt.receiptNumber),
          _line('Ngày/Giờ', timestamp),
          _line('Thu ngân', receipt.cashierCode),
          _line('Bàn', receipt.tableNumber),
          pw.SizedBox(height: 14),
          pw.TableHelper.fromTextArray(
            headers: const ['Món', 'SL', 'Đơn giá', 'Thành tiền'],
            data: receipt.items
                .where((item) => !item.isServiceItem)
                .map(
                  (item) => [
                    item.label,
                    '${item.quantity}',
                    currency.format(item.unitPrice),
                    currency.format(item.lineTotal),
                  ],
                )
                .toList(growable: false),
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            cellAlignments: const {
              1: pw.Alignment.center,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.centerRight,
            },
          ),
          pw.SizedBox(height: 14),
          _amount('Tạm tính', receipt.subtotalAmount, currency),
          if (receipt.serviceChargeAmount > 0)
            _amount('Phí dịch vụ', receipt.serviceChargeAmount, currency),
          if (receipt.discountAmount > 0)
            _amount('Giảm giá', -receipt.discountAmount, currency),
          _amount('VAT (đã gồm)', receipt.vatAmount, currency),
          pw.Divider(),
          _amount(
            receipt.isService ? 'DỊCH VỤ' : 'TỔNG CỘNG',
            receipt.totalAmount,
            currency,
            bold: true,
          ),
          _line('Phương thức', receipt.paymentMethod),
          for (final payment in receipt.payments)
            _line(payment.method, '${currency.format(payment.amount)} VND'),
          _line('Khách trả', '${currency.format(receipt.receivedAmount)} VND'),
          _line('Tiền thừa', '${currency.format(receipt.changeAmount)} VND'),
          pw.SizedBox(height: 24),
          pw.Text(
            'Cảm ơn quý khách!',
            textAlign: pw.TextAlign.center,
            style: pw.TextStyle(fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 6),
          pw.Text(
            'Biên lai này dùng làm chứng từ thanh toán, không phải hóa đơn đỏ.',
            textAlign: pw.TextAlign.center,
            style: const pw.TextStyle(fontSize: 9),
          ),
        ],
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
    await Printing.layoutPdf(onLayout: (_) async => bytes);
  }

  pw.Widget _line(String label, String value) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 2),
    child: pw.Row(
      children: [
        pw.SizedBox(width: 110, child: pw.Text(label)),
        pw.Expanded(child: pw.Text(value)),
      ],
    ),
  );

  pw.Widget _amount(
    String label,
    double amount,
    NumberFormat currency, {
    bool bold = false,
  }) => pw.Padding(
    padding: const pw.EdgeInsets.symmetric(vertical: 3),
    child: pw.Row(
      children: [
        pw.Expanded(
          child: pw.Text(
            label,
            style: bold ? pw.TextStyle(fontWeight: pw.FontWeight.bold) : null,
          ),
        ),
        pw.Text(
          '${currency.format(amount)} VND',
          style: bold ? pw.TextStyle(fontWeight: pw.FontWeight.bold) : null,
        ),
      ],
    ),
  );
}

const digitalReceiptPdfService = DigitalReceiptPdfService();
