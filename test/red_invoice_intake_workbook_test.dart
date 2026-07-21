import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/red_invoice_intake/red_invoice_intake_models.dart';

void main() {
  test(
    'builds a separate MISA-aligned workbook keyed to original receipts',
    () {
      final request = RedInvoiceIntake.fromJson({
        'id': 'intake-1',
        'order_id': 'order-1',
        'store_id': 'store-1',
        'store_name': 'BunsikClub Binh Thanh',
        'meinvoice_job_id': 'misa-ref-1',
        'invoice_series': '1C26TAA',
        'receipt_ids': ['receipt-1', 'receipt-2'],
        'sale_at': '2026-07-21T05:35:42Z',
        'gross_amount': 200000,
        'payment_method': 'Tiền mặt',
        'source': 'zalo',
        'status': 'ready',
        'buyer_tax_code': '0318453298',
        'buyer_unit_code': 'BUYER-01',
        'buyer_legal_name': 'CÔNG TY TNHH BUYER',
        'buyer_full_name': 'Nguyen Van A',
        'buyer_address': 'Ho Chi Minh City',
        'buyer_email': 'buyer@example.com',
        'buyer_email_cc': 'accounting@example.com',
        'buyer_phone': '0900000000',
        'buyer_id': 'ID-001',
        'source_note': 'Corporate Zalo thread 123',
        'attachment_urls': ['https://example.com/evidence'],
        'requested_at': '2026-07-21T05:36:00Z',
        'line_items_snapshot': [
          {
            'order_item_id': 'item-1',
            'display_name': 'Tteokbokki',
            'quantity': 1,
            'unit_price': 92592.59,
            'vat_rate': 8,
            'total_amount_ex_tax': 92592.59,
            'vat_amount': 7407.41,
            'paying_amount_inc_tax': 100000,
          },
          {
            'order_item_id': 'item-2',
            'display_name': 'Kimbap',
            'quantity': 2,
            'unit_price': 46296.30,
            'vat_rate': 8,
            'total_amount_ex_tax': 92592.60,
            'vat_amount': 7407.40,
            'paying_amount_inc_tax': 100000,
          },
        ],
        'meinvoice_status': 'dispatch_paused',
      });
      final export = RedInvoiceDailyExport(
        businessDate: '2026-07-21',
        status: 'finalized',
        finalizedAt: DateTime.parse('2026-07-21T15:20:00Z'),
        requests: [request],
      );

      final workbook = Excel.decodeBytes(
        buildRedInvoiceWorkbook(export: export, exportBatchId: 'batch-1'),
      );

      expect(
        workbook.tables.keys,
        containsAll([
          'Red Invoices',
          'Invoice Details',
          'Intake Audit',
          'Summary',
        ]),
      );
      final invoices = workbook.tables['Red Invoices']!;
      final headers = invoices.rows.first
          .map((cell) => cell?.value.toString())
          .toList();
      expect(
        headers,
        containsAll([
          'RefID',
          'ReceiptIDs',
          'InvSeries',
          'BuyerTaxCode',
          'TotalAmountWithoutVAT',
          'TotalVATAmount',
          'TotalAmount',
        ]),
      );
      expect(invoices.rows[1][1]?.value.toString(), 'misa-ref-1');
      expect(invoices.rows[1][4]?.value.toString(), 'receipt-1;receipt-2');
      expect(invoices.rows[1][13]?.value.toString(), '0318453298');

      final details = workbook.tables['Invoice Details']!;
      expect(details.rows.length, 3);
      expect(details.rows.first[6]?.value.toString(), 'ItemName');
      expect(details.rows[1][6]?.value.toString(), 'Tteokbokki');
      expect(details.rows[1][14]?.value.toString(), '8%');

      final summary = workbook.tables['Summary']!;
      expect(
        summary.rows.last[1]?.value.toString(),
        'Match ReceiptIDs to the original restaurant sales export',
      );
    },
  );

  test('refuses pending, empty, and missing-line-item exports', () {
    final requestWithoutItems = RedInvoiceIntake.fromJson({
      'id': 'intake-1',
      'order_id': 'order-1',
      'store_id': 'store-1',
      'sale_at': '2026-07-21T05:35:42Z',
      'requested_at': '2026-07-21T05:36:00Z',
      'line_items_snapshot': const [],
    });

    expect(
      () => buildRedInvoiceWorkbook(
        export: const RedInvoiceDailyExport(
          businessDate: '2026-07-21',
          status: 'pending',
          finalizedAt: null,
          requests: [],
        ),
        exportBatchId: 'batch-1',
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'RED_INVOICE_EXPORT_NOT_READY',
        ),
      ),
    );
    expect(
      () => buildRedInvoiceWorkbook(
        export: const RedInvoiceDailyExport(
          businessDate: '2026-07-21',
          status: 'finalized',
          finalizedAt: null,
          requests: [],
        ),
        exportBatchId: 'batch-1',
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'RED_INVOICE_EXPORT_EMPTY',
        ),
      ),
    );
    expect(
      () => buildRedInvoiceWorkbook(
        export: RedInvoiceDailyExport(
          businessDate: '2026-07-21',
          status: 'finalized',
          finalizedAt: null,
          requests: [requestWithoutItems],
        ),
        exportBatchId: 'batch-1',
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'RED_INVOICE_EXPORT_LINE_ITEMS_REQUIRED',
        ),
      ),
    );
  });
}
