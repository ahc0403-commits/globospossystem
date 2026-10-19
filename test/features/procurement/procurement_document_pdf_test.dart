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
            for (final key in procurementDocumentLabelKeys)
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
            printedAt: DateTime.utc(2026, 10, 7, 2, 30),
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
  for (final locale in ['ko', 'en', 'vi']) {
    test(
      'unpriced draft shows incomplete totals and pending approval ($locale)',
      () async {
        final bytes = await buildProcurementDocumentPdf(
          {
            'kind': 'pr',
            'audience': 'internal',
            'data': {
              'request_no': 'PR-INCOMPLETE',
              'status': 'draft',
              'store_name': 'Example store',
              'created_at': '2026-10-06T17:30:00Z',
              'requested_delivery_date': '2026-10-09',
              'purchase_category': 'beverage',
              'reason': 'Example only; one price is not registered',
              'estimates_complete': false,
              'lines': [
                {
                  'product_name': 'Known estimate item',
                  'requested_quantity': 1,
                  'requested_unit': 'box',
                  'quantity_base': 1,
                  'estimated_conversion': 1,
                  'estimated_unit_price': 12345.67,
                  'estimated_amount': 12345.67,
                  'estimated_tax_rate': 8,
                  'estimated_order_unit': 'box',
                },
                {
                  'product_name': 'Unpriced item',
                  'requested_quantity': 2,
                  'requested_unit': 'box',
                  'quantity_base': 2,
                },
              ],
            },
          },
          labels: {
            for (final key in procurementDocumentLabelKeys)
              key: procurementProcessLabel(key, locale),
          },
          fontAsset: 'assets/fonts/PretendardVariable.ttf',
          printedAt: DateTime.utc(2026, 10, 7, 2, 30),
        );
        final dir = Directory(
          '${Directory.systemTemp.path}/procurement-pr-layout-20261007',
        );
        await dir.create(recursive: true);
        await File('${dir.path}/pr-incomplete-$locale.pdf').writeAsBytes(bytes);
        expect(ascii.decode(bytes.take(5).toList()), '%PDF-');
      },
    );
    for (final count in [1, 11, 50]) {
      test('$count-line multilingual PR layout ($locale)', () async {
        final data = {
          'request_no': 'PR-EXAMPLE-20261007',
          'status': 'submitted',
          'store_name': 'GLOBOS 예시 매장 / Cửa hàng mẫu',
          'created_at': '2026-10-06T17:30:00Z',
          'submitted_at': '2026-10-07T01:30:00Z',
          'requested_delivery_date': '2026-10-09',
          'created_actor': {'display_name': '예시 요청자 / Người yêu cầu mẫu'},
          'purchase_category': 'beverage',
          'reason': '교육·검토용 가상 데이터 / Dữ liệu giả để kiểm tra bố cục',
          'memo': '행과 단위·금액이 여러 페이지에서도 유지되는지 확인합니다.',
          'estimates_complete': true,
          'estimated_net': count * 12345.67,
          'estimated_vat': count * 987.65,
          'estimated_total': count * 13333.32,
          'lines': List.generate(
            count,
            (i) => {
              'product_name':
                  '${i + 1}. 원재료 / Nước giải khát không đường chai thủy tinh',
              'specification_snapshot': '330 ml × 24 / 긴 규격 표시 확인',
              'requested_quantity': 1.125,
              'requested_unit': 'thùng',
              'quantity_base': 27,
              'estimated_conversion': 24,
              'estimated_unit_price': 10973.93,
              'estimated_amount': 12345.67,
              'estimated_tax_rate': 8,
              'estimated_order_unit': 'thùng 24 chai',
              'current_stock_snapshot': 2.375,
              'memo': '필요일 확인 / Kiểm tra ngày cần hàng',
            },
          ),
        };
        final bytes = await buildProcurementDocumentPdf(
          {'kind': 'pr', 'audience': 'internal', 'data': data},
          labels: {
            for (final key in procurementDocumentLabelKeys)
              key: procurementProcessLabel(key, locale),
          },
          fontAsset: 'assets/fonts/PretendardVariable.ttf',
          printedAt: DateTime.utc(2026, 10, 7, 2, 30),
        );
        final dir = Directory(
          '${Directory.systemTemp.path}/procurement-pr-layout-20261007',
        );
        await dir.create(recursive: true);
        await File('${dir.path}/pr-$count-$locale.pdf').writeAsBytes(bytes);
        expect(bytes.length, greaterThan(1000));
      });
    }
  }
}
