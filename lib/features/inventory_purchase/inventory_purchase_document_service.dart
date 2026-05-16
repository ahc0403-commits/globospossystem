import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

class InventoryPurchaseDocumentService {
  const InventoryPurchaseDocumentService();

  Future<bool> layoutPurchaseOrderPdf({
    required Map<String, dynamic> order,
    required List<Map<String, dynamic>> lines,
  }) {
    final orderNo = _string(
      order['purchase_order_no'],
      fallback: 'purchase_order',
    );
    return Printing.layoutPdf(
      name: '$orderNo.pdf',
      onLayout: (_) => buildPurchaseOrderPdf(order: order, lines: lines),
    );
  }

  Future<Uint8List> buildPurchaseOrderPdf({
    required Map<String, dynamic> order,
    required List<Map<String, dynamic>> lines,
  }) async {
    final regular = await PdfGoogleFonts.notoSansKRRegular();
    final bold = await PdfGoogleFonts.notoSansKRBold();
    final document = pw.Document(
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
    );
    final orderNo = _string(order['purchase_order_no'], fallback: '-');
    final supplierName = _nestedName(order['supplier']);
    final requestedDate = _date(order['requested_delivery_date']);
    final status = _statusLabel(order['status']);
    final supplyAmount = _num(order['total_supply_amount']);
    final taxAmount = _num(order['tax_amount']);
    final totalAmount = _num(order['total_amount']);

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.all(32),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.center,
          child: pw.Text(
            'QSC Manager',
            style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
        ),
        build: (context) => [
          pw.Row(
            crossAxisAlignment: pw.CrossAxisAlignment.start,
            children: [
              pw.Expanded(
                child: pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      '발주서',
                      style: pw.TextStyle(
                        fontSize: 28,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 8),
                    pw.Text('공급처: $supplierName'),
                    pw.Text('발주번호: $orderNo'),
                    pw.Text('납품요청일: $requestedDate'),
                    pw.Text('상태: $status'),
                  ],
                ),
              ),
              pw.Container(
                padding: const pw.EdgeInsets.all(10),
                decoration: pw.BoxDecoration(
                  border: pw.Border.all(color: PdfColors.grey400),
                ),
                child: pw.BarcodeWidget(
                  barcode: pw.Barcode.code128(),
                  data: orderNo,
                  width: 130,
                  height: 42,
                  drawText: false,
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 24),
          pw.Text(
            '발주 상품 내역',
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 8),
          pw.TableHelper.fromTextArray(
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellAlignment: pw.Alignment.centerLeft,
            headers: const ['No.', '상품명', '발주수량', '단위', '단가', '공급가액', '메모'],
            data: [
              for (var index = 0; index < lines.length; index++)
                [
                  '${index + 1}',
                  _nestedName(lines[index]['product']),
                  _quantity(lines[index]['ordered_quantity_unit']),
                  _string(lines[index]['order_unit'], fallback: '-'),
                  _money(lines[index]['unit_price']),
                  _money(lines[index]['supply_amount']),
                  _string(lines[index]['memo'], fallback: '-'),
                ],
            ],
          ),
          pw.SizedBox(height: 18),
          pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Container(
              width: 240,
              child: pw.Table(
                border: pw.TableBorder.all(color: PdfColors.grey400),
                children: [
                  _totalRow('공급가액 합계', _money(supplyAmount)),
                  _totalRow('부가세', _money(taxAmount)),
                  _totalRow('총 발주 금액', _money(totalAmount), strong: true),
                ],
              ),
            ),
          ),
          pw.SizedBox(height: 18),
          pw.Text(
            'Office 승인/반려/수정은 Office 앱에서만 처리합니다. POS는 발주서 출력, 입고 확인, 상태 조회를 담당합니다.',
            style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700),
          ),
        ],
      ),
    );

    return document.save();
  }

  pw.TableRow _totalRow(String label, String value, {bool strong = false}) {
    final style = pw.TextStyle(
      fontSize: 10,
      fontWeight: strong ? pw.FontWeight.bold : pw.FontWeight.normal,
    );
    return pw.TableRow(
      children: [
        pw.Padding(
          padding: const pw.EdgeInsets.all(7),
          child: pw.Text(label, style: style),
        ),
        pw.Padding(
          padding: const pw.EdgeInsets.all(7),
          child: pw.Align(
            alignment: pw.Alignment.centerRight,
            child: pw.Text(value, style: style),
          ),
        ),
      ],
    );
  }
}

const inventoryPurchaseDocumentService = InventoryPurchaseDocumentService();

String _money(Object? value) {
  final formatter = NumberFormat.currency(
    locale: 'ko_KR',
    symbol: '₩ ',
    decimalDigits: 0,
  );
  return formatter.format(_num(value));
}

num _num(Object? value) {
  if (value is num) return value;
  return num.tryParse(value?.toString() ?? '') ?? 0;
}

String _quantity(Object? value) =>
    NumberFormat('#,##0.###').format(_num(value));

String _string(Object? value, {String fallback = ''}) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? fallback : text;
}

String _date(Object? value) {
  final text = _string(value, fallback: '-');
  if (text.length >= 10) return text.substring(0, 10);
  return text;
}

String _nestedName(Object? value) {
  if (value is Map) {
    return _string(value['name'] ?? value['supplier_name'], fallback: '-');
  }
  return _string(value, fallback: '-');
}

String _statusLabel(Object? value) {
  return switch (_string(value)) {
    'draft' => '임시',
    'submitted' => '승인 대기',
    'office_approved' => 'Office 승인',
    'office_returned' => '반환',
    'office_rejected' => '반려',
    'ordered' => '발주 진행',
    'partially_received' => '부분 입고',
    'received' => '입고 완료',
    'cancelled' => '취소',
    _ => _string(value, fallback: '-'),
  };
}
