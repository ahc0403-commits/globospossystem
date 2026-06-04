import 'dart:typed_data';

import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

import '../../l10n/app_localizations.dart';

class InventoryPurchaseDocumentService {
  const InventoryPurchaseDocumentService();

  Future<bool> layoutPurchaseOrderPdf({
    required Map<String, dynamic> order,
    required List<Map<String, dynamic>> lines,
    required AppLocalizations l10n,
  }) {
    final orderNo = _string(
      order['purchase_order_no'],
      fallback: 'purchase_order',
    );
    return Printing.layoutPdf(
      name: '$orderNo.pdf',
      onLayout: (_) =>
          buildPurchaseOrderPdf(order: order, lines: lines, l10n: l10n),
    );
  }

  Future<Uint8List> buildPurchaseOrderPdf({
    required Map<String, dynamic> order,
    required List<Map<String, dynamic>> lines,
    required AppLocalizations l10n,
  }) async {
    final regular = await PdfGoogleFonts.notoSansKRRegular();
    final bold = await PdfGoogleFonts.notoSansKRBold();
    final document = pw.Document(
      theme: pw.ThemeData.withFont(base: regular, bold: bold),
    );
    final orderNo = _string(order['purchase_order_no'], fallback: '-');
    final supplierName = _nestedName(order['supplier']);
    final requestedDate = _date(order['requested_delivery_date']);
    final status = _statusLabel(order['status'], l10n);
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
                      l10n.inventoryPurchasePdfTitle,
                      style: pw.TextStyle(
                        fontSize: 28,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.SizedBox(height: 8),
                    pw.Text(l10n.inventoryPurchasePdfSupplier(supplierName)),
                    pw.Text(l10n.inventoryPurchasePdfOrderNo(orderNo)),
                    pw.Text(
                      l10n.inventoryPurchasePdfRequestedDate(requestedDate),
                    ),
                    pw.Text(l10n.inventoryPurchasePdfStatus(status)),
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
            l10n.inventoryPurchasePdfProductLines,
            style: pw.TextStyle(fontSize: 14, fontWeight: pw.FontWeight.bold),
          ),
          pw.SizedBox(height: 8),
          pw.TableHelper.fromTextArray(
            headerDecoration: const pw.BoxDecoration(color: PdfColors.grey200),
            headerStyle: pw.TextStyle(fontWeight: pw.FontWeight.bold),
            cellStyle: const pw.TextStyle(fontSize: 9),
            cellAlignment: pw.Alignment.centerLeft,
            headers: [
              l10n.inventoryPurchasePdfLineNo,
              l10n.inventoryPurchaseProductName,
              l10n.inventoryPurchaseOrderQuantity,
              l10n.inventoryPurchaseUnit,
              l10n.inventoryPurchaseUnitPrice,
              l10n.inventoryPurchaseSupplyAmount,
              l10n.inventoryPurchaseMemo,
            ],
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
                  _totalRow(
                    l10n.inventoryPurchasePdfSupplyAmountTotal,
                    _money(supplyAmount),
                  ),
                  _totalRow(l10n.inventoryPurchaseTaxAmount, _money(taxAmount)),
                  _totalRow(
                    l10n.inventoryPurchasePdfTotalAmount,
                    _money(totalAmount),
                    strong: true,
                  ),
                ],
              ),
            ),
          ),
          pw.SizedBox(height: 18),
          pw.Text(
            l10n.inventoryPurchasePdfOfficeNote,
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
  final formatter = NumberFormat('#,###', 'vi_VN');
  return '${formatter.format(_num(value))} VND';
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

String _statusLabel(Object? value, AppLocalizations l10n) {
  return switch (_string(value)) {
    'draft' => l10n.inventoryPurchaseStatusDraft,
    'submitted' => l10n.inventoryPurchaseStatusSubmitted,
    'office_approved' => l10n.inventoryPurchaseStatusOfficeApproved,
    'office_returned' => l10n.inventoryPurchaseStatusOfficeReturned,
    'office_rejected' => l10n.inventoryPurchaseStatusOfficeRejected,
    'ordered' => l10n.inventoryPurchaseStatusOrdered,
    'partially_received' => l10n.inventoryPurchaseStatusPartiallyReceived,
    'received' => l10n.inventoryPurchaseStatusReceived,
    'cancelled' => l10n.inventoryPurchaseStatusCancelled,
    _ => _string(value, fallback: '-'),
  };
}
