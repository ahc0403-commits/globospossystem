import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/digital_receipt_pdf_service.dart';
import 'package:globos_pos_system/features/digital_receipt/digital_receipt_model.dart';
import 'package:pdf/pdf.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'builds a content-height 80mm receipt instead of an A4 document',
    () async {
      expect(
        digitalReceiptPdfPageFormat.width,
        closeTo(80 * PdfPageFormat.mm, 0.01),
      );
      expect(digitalReceiptPdfPageFormat.height, double.infinity);
      expect(
        digitalReceiptPrintPageFormat.width,
        closeTo(80 * PdfPageFormat.mm, 0.01),
      );

      final bytes = await digitalReceiptPdfService.build(_receipt);
      final source = latin1.decode(bytes, allowInvalid: true);
      final mediaBox = RegExp(
        r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*\]',
      ).firstMatch(source);

      expect(bytes, isNotEmpty);
      expect(mediaBox, isNotNull);
      expect(
        double.parse(mediaBox!.group(1)!),
        closeTo(80 * PdfPageFormat.mm, 0.1),
      );
      expect(
        double.parse(mediaBox.group(2)!),
        lessThan(PdfPageFormat.a4.height),
      );
    },
  );
}

final _receipt = DigitalReceipt(
  id: 'receipt-1',
  orderId: 'order-1',
  receiptNumber: 'BC-20260816-000001',
  restaurantName: 'BUNSIK CLUB',
  legalName: 'CÔNG TY TNHH AKJ INTERNATIONAL',
  taxCode: '0318453298',
  addressLines: [
    '69/1A2 Nguyễn Gia Trí',
    'Phường Thạnh Mỹ Tây, Thành phố Hồ Chí Minh',
  ],
  tableNumber: '101',
  cashierCode: 'sp_pos',
  paidAt: DateTime(2026, 8, 16, 17, 50),
  items: [
    DigitalReceiptItem(
      label: 'Combo Donkatsu + Mì lạnh trộn + Kimbap thịt heo cay + Trứng cuộn',
      quantity: 1,
      unitPrice: 260000,
      lineTotal: 260000,
      isServiceItem: false,
    ),
  ],
  payments: [DigitalReceiptPayment(method: 'BANKTRANSFER', amount: 280800)],
  subtotalAmount: 260000,
  serviceChargeAmount: 0,
  discountAmount: 0,
  vatAmount: 20800,
  totalAmount: 280800,
  receivedAmount: 280800,
  changeAmount: 0,
  paymentMethod: 'BANKTRANSFER',
  isService: false,
);
