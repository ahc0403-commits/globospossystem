import 'dart:io';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/procurement/procurement_document_pdf.dart';
import 'package:globos_pos_system/features/procurement/procurement_process_labels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final locale in ['ko', 'en', 'vi']) {
    for (final supplier in [true, false]) {
      test(
        '200-line ${supplier ? 'supplier PO' : 'internal PR'} PDF ($locale)',
        () async {
          final labels = {
            for (final key in [
              'titlePo',
              'titlePr',
              'dates',
              'category',
              'channel',
              'stationery',
              'shopee',
              'reason',
              'item',
              'specification',
              'quantity',
              'unit',
              'notes',
              'estimate',
              'amount',
              'stock',
              'approveStore',
              'approveBrand',
              'approvePurchase',
              'expectedVat',
              'expectedTotal',
            ])
              key: procurementProcessLabel(key, locale),
          };
          final source = {
            'kind': supplier ? 'po' : 'pr',
            'audience': supplier ? 'supplier' : 'internal',
            'data': {
              'purchase_order_no': 'PO-TEST',
              'request_no': 'PR-TEST',
              'store_name': 'GLOBOS test',
              'created_at': '2026-10-01',
              'submitted_at': '2026-10-02',
              'issued_at': '2026-10-03',
              'pr_created_at': '2026-10-01',
              'pr_submitted_at': '2026-10-02',
              'requested_delivery_date': '2026-10-06',
              'supplier_name': 'Supplier TEST',
              'delivery_address': 'Test store address',
              'contact_name': 'Receiver TEST',
              'purchase_category': 'stationery',
              'purchase_channel': 'shopee',
              'reason': 'Test stationery',
              'estimates_complete': true,
              'estimated_total': 15678.9,
              'estimated_vat': 567.89,
              'total_amount': '987654321.55',
              'supplier_bank_account': 'PRIVATE_BANK_TEST',
              'approval_snapshot': {'secret': 'PRIVATE_APPROVAL_TEST'},
              'lines': List.generate(
                200,
                (i) => {
                  'product_name': 'Test item $i',
                  'specification': 'A4',
                  'specification_snapshot': 'A4',
                  'quantity': 1,
                  'requested_quantity': 1,
                  'unit': 'box',
                  'requested_unit': 'box',
                  'quantity_base': 10,
                  'estimated_conversion': 10,
                  'estimated_unit_price': 12.34,
                  'estimated_tax_rate': 8,
                  'estimated_order_unit': 'box',
                  'current_stock_snapshot': 0,
                  'memo': 'Test note $i',
                  'unit_price': '987654321.55',
                  'tax_rate_snapshot': 999,
                },
              ),
              for (final stage in ['store', 'brand', 'office'])
                '${stage}_approved_actor': {
                  'display_name': 'Approved TEST $stage',
                },
              for (final stage in ['store', 'brand', 'office'])
                '${stage}_approved_at': '2026-10-03',
            },
          };
          final bytes = await buildProcurementDocumentPdf(
            source,
            labels: labels,
            fontAsset: 'assets/fonts/PretendardVariable.ttf',
          );
          expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
          expect(bytes.length, greaterThan(1000));
          final dir = Directory(
            Platform.environment['PROCUREMENT_PDF_OUTPUT'] ??
                '${Directory.systemTemp.path}/procurement-pdf-globos_pos_system',
          );
          await dir.create(recursive: true);
          await File(
            '${dir.path}/${supplier ? 'supplier-po' : 'internal-pr'}-$locale.pdf',
          ).writeAsBytes(bytes);
        },
      );
    }
  }
}
