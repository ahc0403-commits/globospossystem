import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:intl/intl.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';
import 'package:supabase_flutter/supabase_flutter.dart' show FileOptions;

import '../../core/services/inventory_service.dart';
import '../../core/ui/app_fonts.dart';
import '../../l10n/app_localizations.dart';
import '../../main.dart';

class InventoryPurchasePublishedDocument {
  const InventoryPurchasePublishedDocument({
    required this.storagePath,
    required this.sha256Hash,
    required this.byteSize,
  });

  final String storagePath;
  final String sha256Hash;
  final int byteSize;
}

class InventoryPurchaseDocumentService {
  const InventoryPurchaseDocumentService();

  Future<InventoryPurchasePublishedDocument> publishApprovedPurchaseOrder({
    required Map<String, dynamic> order,
    required List<Map<String, dynamic>> lines,
    required AppLocalizations l10n,
  }) async {
    final orderId = _string(order['id']);
    final storeId = _string(order['restaurant_id']);
    final snapshotVersion = _num(order['approval_snapshot_version']).toInt();
    if (orderId.isEmpty || storeId.isEmpty || snapshotVersion <= 0) {
      throw StateError('INVENTORY_PURCHASE_DOCUMENT_SNAPSHOT_INVALID');
    }

    try {
      final bytes = await buildPurchaseOrderPdf(
        order: order,
        lines: lines,
        l10n: l10n,
      );
      final hash = sha256.convert(bytes).toString();
      final storagePath = '$storeId/$orderId/v$snapshotVersion.pdf';
      await supabase.storage
          .from('inventory-purchase-documents')
          .uploadBinary(
            storagePath,
            bytes,
            fileOptions: const FileOptions(
              contentType: 'application/pdf',
              upsert: true,
            ),
          );
      await inventoryService.recordInventoryPurchaseDocumentResult(
        purchaseOrderId: orderId,
        snapshotVersion: snapshotVersion,
        success: true,
        storagePath: storagePath,
        sha256: hash,
        byteSize: bytes.length,
      );
      return InventoryPurchasePublishedDocument(
        storagePath: storagePath,
        sha256Hash: hash,
        byteSize: bytes.length,
      );
    } catch (error) {
      try {
        await inventoryService.recordInventoryPurchaseDocumentResult(
          purchaseOrderId: orderId,
          snapshotVersion: snapshotVersion,
          success: false,
          error: error.toString(),
        );
      } catch (_) {
        // Keep the original generation or upload error for the UI.
      }
      rethrow;
    }
  }

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
    final fontData = await rootBundle.load(AppFonts.assetPath);
    final regular = pw.Font.ttf(fontData);
    final document = pw.Document(
      theme: pw.ThemeData.withFont(base: regular, bold: regular),
    );
    final orderNo = _string(order['purchase_order_no'], fallback: '-');
    final supplierName = _nestedName(order['supplier']);
    final storeName = _nestedName(order['store']);
    final requestedDate = _date(order['requested_delivery_date']);
    final status = _statusLabel(order['status'], l10n);
    final supplyAmount = _num(order['total_supply_amount']);
    final taxAmount = _num(order['tax_amount']);
    final totalAmount = _num(order['total_amount']);

    document.addPage(
      pw.MultiPage(
        pageFormat: PdfPageFormat.a4,
        margin: const pw.EdgeInsets.fromLTRB(30, 28, 30, 28),
        footer: (context) => pw.Align(
          alignment: pw.Alignment.center,
          child: pw.Text(
            'QSC Manager · $orderNo · ${context.pageNumber}/${context.pagesCount}',
            style: pw.TextStyle(fontSize: 9, color: PdfColors.grey600),
          ),
        ),
        build: (context) => [
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.symmetric(
              horizontal: 18,
              vertical: 16,
            ),
            decoration: const pw.BoxDecoration(
              color: PdfColor.fromInt(0xff0b4f8a),
            ),
            child: pw.Row(
              mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
              crossAxisAlignment: pw.CrossAxisAlignment.center,
              children: [
                pw.Column(
                  crossAxisAlignment: pw.CrossAxisAlignment.start,
                  children: [
                    pw.Text(
                      '발 주 서',
                      style: pw.TextStyle(
                        color: PdfColors.white,
                        fontSize: 26,
                        fontWeight: pw.FontWeight.bold,
                      ),
                    ),
                    pw.Text(
                      'PURCHASE ORDER',
                      style: const pw.TextStyle(
                        color: PdfColor.fromInt(0xffd8eafa),
                        fontSize: 10,
                        letterSpacing: 1.8,
                      ),
                    ),
                  ],
                ),
                pw.Container(
                  padding: const pw.EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 7,
                  ),
                  decoration: pw.BoxDecoration(
                    color: PdfColors.white,
                    borderRadius: pw.BorderRadius.circular(4),
                  ),
                  child: pw.Text(
                    status,
                    style: pw.TextStyle(
                      color: const PdfColor.fromInt(0xff0b4f8a),
                      fontSize: 11,
                      fontWeight: pw.FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ),
          ),
          pw.SizedBox(height: 14),
          pw.Table(
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.6),
            columnWidths: const {
              0: pw.FixedColumnWidth(90),
              1: pw.FlexColumnWidth(),
              2: pw.FixedColumnWidth(90),
              3: pw.FlexColumnWidth(),
            },
            children: [
              _infoRow('발주번호 / PO No.', orderNo, '매장 / Store', storeName),
              _infoRow('거래처 / Supplier', supplierName, '납품 요청일', requestedDate),
              _infoRow(
                '발주일 / Issued',
                _date(order['brand_approved_at']),
                '품목 수 / Items',
                '${lines.length}',
              ),
            ],
          ),
          pw.SizedBox(height: 18),
          pw.Text(
            '발주 품목 / ORDER ITEMS',
            style: pw.TextStyle(
              fontSize: 13,
              color: const PdfColor.fromInt(0xff0b4f8a),
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 8),
          pw.TableHelper.fromTextArray(
            border: pw.TableBorder.all(color: PdfColors.grey400, width: 0.5),
            headerDecoration: const pw.BoxDecoration(
              color: PdfColor.fromInt(0xffe9f2f9),
            ),
            headerStyle: pw.TextStyle(
              fontSize: 8,
              fontWeight: pw.FontWeight.bold,
            ),
            cellStyle: const pw.TextStyle(fontSize: 8),
            cellAlignments: const {
              0: pw.Alignment.center,
              1: pw.Alignment.centerLeft,
              2: pw.Alignment.centerRight,
              3: pw.Alignment.center,
              4: pw.Alignment.centerRight,
              5: pw.Alignment.centerRight,
              6: pw.Alignment.centerRight,
              7: pw.Alignment.centerRight,
            },
            columnWidths: const {
              0: pw.FixedColumnWidth(25),
              1: pw.FlexColumnWidth(2.4),
              2: pw.FlexColumnWidth(0.8),
              3: pw.FlexColumnWidth(0.7),
              4: pw.FlexColumnWidth(1.2),
              5: pw.FlexColumnWidth(1.2),
              6: pw.FlexColumnWidth(1.0),
              7: pw.FlexColumnWidth(1.25),
            },
            headers: const ['No.', '품목명', '수량', '단위', '단가', '공급가', 'VAT', '합계'],
            data: [
              for (var index = 0; index < lines.length; index++)
                [
                  '${index + 1}',
                  _nestedName(lines[index]['product']),
                  _quantity(lines[index]['ordered_quantity_unit']),
                  _string(lines[index]['order_unit'], fallback: '-'),
                  _money(lines[index]['unit_price']),
                  _money(lines[index]['supply_amount']),
                  _money(lines[index]['tax_amount']),
                  _money(
                    _num(lines[index]['supply_amount']) +
                        _num(lines[index]['tax_amount']),
                  ),
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
          if (_string(order['memo']).isNotEmpty) ...[
            pw.SizedBox(height: 14),
            pw.Container(
              width: double.infinity,
              padding: const pw.EdgeInsets.all(9),
              decoration: pw.BoxDecoration(
                color: PdfColors.grey100,
                border: pw.Border.all(color: PdfColors.grey300),
              ),
              child: pw.Text('비고 / Memo: ${_string(order['memo'])}'),
            ),
          ],
          pw.SizedBox(height: 18),
          pw.Text(
            '승인 이력 / APPROVAL HISTORY',
            style: pw.TextStyle(
              fontSize: 13,
              color: const PdfColor.fromInt(0xff0b4f8a),
              fontWeight: pw.FontWeight.bold,
            ),
          ),
          pw.SizedBox(height: 8),
          pw.Row(
            children: [
              pw.Expanded(
                child: _approvalCell(
                  '발주 담당',
                  _string(
                    order['created_by_name'],
                    fallback: _string(order['created_by'], fallback: '-'),
                  ),
                  _dateTime(order['submitted_at'] ?? order['created_at']),
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: _approvalCell(
                  '스토어 매니저 승인',
                  _string(
                    order['store_approved_by_name'],
                    fallback: _string(
                      order['store_approved_by'],
                      fallback: '-',
                    ),
                  ),
                  _dateTime(order['store_approved_at']),
                ),
              ),
              pw.SizedBox(width: 8),
              pw.Expanded(
                child: _approvalCell(
                  '브랜드 매니저 최종 승인',
                  _string(
                    order['brand_approved_by_name'],
                    fallback: _string(
                      order['brand_approved_by'],
                      fallback: '-',
                    ),
                  ),
                  _dateTime(order['brand_approved_at']),
                ),
              ),
            ],
          ),
          pw.SizedBox(height: 18),
          pw.Container(
            width: double.infinity,
            padding: const pw.EdgeInsets.all(11),
            decoration: pw.BoxDecoration(
              border: pw.Border.all(color: const PdfColor.fromInt(0xff0b4f8a)),
              color: const PdfColor.fromInt(0xfff3f8fc),
            ),
            child: pw.Text(
              '본 발주서는 스토어 매니저와 브랜드 매니저의 승인을 완료한 공식 발주 내역입니다. '
              '재고는 실제 수령 후 회계 담당자의 최종 입고 확정 시점에 반영됩니다.',
              style: const pw.TextStyle(fontSize: 9),
            ),
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

  pw.TableRow _infoRow(
    String labelA,
    String valueA,
    String labelB,
    String valueB,
  ) => pw.TableRow(
    children: [
      _infoCell(labelA, label: true),
      _infoCell(valueA),
      _infoCell(labelB, label: true),
      _infoCell(valueB),
    ],
  );

  pw.Widget _infoCell(String value, {bool label = false}) => pw.Container(
    color: label ? const PdfColor.fromInt(0xfff1f4f6) : null,
    padding: const pw.EdgeInsets.symmetric(horizontal: 7, vertical: 8),
    child: pw.Text(
      value,
      style: pw.TextStyle(
        fontSize: 9,
        fontWeight: label ? pw.FontWeight.bold : pw.FontWeight.normal,
      ),
    ),
  );

  pw.Widget _approvalCell(String role, String name, String approvedAt) =>
      pw.Container(
        height: 82,
        padding: const pw.EdgeInsets.all(9),
        decoration: pw.BoxDecoration(
          border: pw.Border.all(color: PdfColors.grey400),
        ),
        child: pw.Column(
          crossAxisAlignment: pw.CrossAxisAlignment.start,
          mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
          children: [
            pw.Text(
              role,
              style: pw.TextStyle(fontSize: 9, fontWeight: pw.FontWeight.bold),
            ),
            pw.Text(name, style: const pw.TextStyle(fontSize: 9)),
            pw.Text(
              approvedAt,
              style: const pw.TextStyle(fontSize: 8, color: PdfColors.grey700),
            ),
          ],
        ),
      );
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
    'store_approved' => 'Store approved',
    'brand_approved' => 'Brand approved',
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

String _dateTime(Object? value) {
  final raw = _string(value, fallback: '-');
  final parsed = DateTime.tryParse(raw)?.toLocal();
  return parsed == null ? raw : DateFormat('yyyy-MM-dd HH:mm').format(parsed);
}
