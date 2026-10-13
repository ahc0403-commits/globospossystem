import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/procurement/procurement_presentation.dart';
import 'package:globos_pos_system/features/procurement/procurement_receipt_report_pdf.dart';
import 'package:globos_pos_system/features/procurement/procurement_document_pdf.dart';
import 'package:globos_pos_system/features/procurement/procurement_process_labels.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'carryover groups by material and supplier, preserving each original PO',
    () {
      final rows = procurementCarryoverLines([
        {
          'product_id': 'a',
          'supplier_id': 's1',
          'base_unit': 'g',
          'shortage_quantity_base': 3,
          'original_order_line_id': 'l1',
          'purchase_order_no': 'PO-1',
        },
        {
          'product_id': 'a',
          'supplier_id': 's1',
          'base_unit': 'g',
          'shortage_quantity_base': 2,
          'original_order_line_id': 'l2',
          'purchase_order_no': 'PO-2',
        },
        {
          'product_id': 'a',
          'supplier_id': 's2',
          'base_unit': 'g',
          'shortage_quantity_base': 1,
          'original_order_line_id': 'l3',
          'purchase_order_no': 'PO-3',
        },
      ]);
      expect(rows, hasLength(2));
      expect(rows.first['quantity'], '5');
      expect(rows.first['shortage_sources'], hasLength(2));
      expect(rows.last['preferred_supplier_id'], 's2');
    },
  );
  test(
    'display price uses requested units while the authoritative amount stays intact',
    () {
      final line = {
        'estimated_unit_price': 30000,
        'estimated_conversion': 1000,
        'conversion_snapshot': 1,
        'estimated_amount': 210,
      };
      expect(procurementDisplayUnitPrice(line), 30);
      expect(line['estimated_amount'], 210);
      expect(
        procurementDisplayUnitPrice({'estimated_unit_price': null}),
        isNull,
      );
    },
  );
  test(
    'later receiving reduces carried shortage while preserving new demand',
    () {
      final original = <String, dynamic>{
        'product_id': 'p',
        'requested_unit': 'g',
        'requested_quantity': 5,
        'quantity_base': 5,
        'conversion_snapshot': 1,
        'shortage_sources': [
          {'original_order_line_id': 'old', 'quantity_base': 3},
        ],
      };
      final refreshed = procurementRefreshCarryoverLines(
        [original],
        [
          {'original_order_line_id': 'old', 'shortage_quantity_base': 2},
        ],
      );
      expect(refreshed.single['requested_quantity'], 4);
      expect(procurementShortageBase(refreshed.single), 2);
      expect(original['requested_quantity'], 5);
      final fulfilled = procurementRefreshCarryoverLines([
        {...original, 'quantity_base': 3, 'requested_quantity': 3},
      ], []);
      expect(fulfilled, isEmpty);
    },
  );
  for (final language in ['ko', 'en', 'vi']) {
    test(
      'policy-3 PR material codes, carried shortage and two approval rows ($language)',
      () async {
        final bytes = await buildProcurementDocumentPdf(
          {
            'kind': 'pr',
            'audience': 'internal',
            'data': {
              'request_no': 'PR-TWO-STAGE-TEST',
              'store_name': 'Test store',
              'reason': 'Fixture request',
              'approval_policy_version': 3,
              'status': 'approved',
              'created_at': '2026-10-13T03:00:00Z',
              'requested_delivery_date': '2026-10-15',
              'purchase_category': 'raw_material',
              'store_approved_actor': {'display_name': 'SM TEST'},
              'store_approved_at': '2026-10-13T03:00:00Z',
              'office_approved_actor': {'display_name': 'BUYER TEST'},
              'office_approved_at': '2026-10-13T03:30:00Z',
              'brand_approved_actor': {'display_name': 'UNUSED BM TEST'},
              'brand_approved_at': '2026-10-13T03:15:00Z',
              'estimates_complete': true,
              'estimated_net': 66210,
              'estimated_vat': 0,
              'estimated_total': 66210,
              'lines': [
                {
                  'product_name': 'Previous shortage material',
                  'product_code': 'RAW-CARRY-001',
                  'requested_quantity': 7,
                  'requested_unit': 'g',
                  'conversion_snapshot': 1,
                  'quantity_base': 7,
                  'estimated_unit_price': 30000,
                  'estimated_conversion': 1000,
                  'estimated_order_unit': 'box',
                  'estimated_amount': 210,
                  'estimated_tax_rate': 0,
                  'current_stock_snapshot': 7,
                  'shortage_quantity': 3,
                  'shortage_sources': [
                    {'purchase_order_no': 'PO-PREVIOUS-001'},
                  ],
                },
                {
                  'product_name': 'Kim chi / 김치',
                  'product_code': 'RAW-002',
                  'requested_quantity': 2,
                  'requested_unit': 'Thùng(박스)',
                  'conversion_snapshot': 1000,
                  'quantity_base': 2000,
                  'estimated_unit_price': 33000,
                  'estimated_conversion': 1000,
                  'estimated_order_unit': 'Thùng(박스)',
                  'estimated_amount': 66000,
                  'estimated_tax_rate': 0,
                  'current_stock_snapshot': 1000,
                },
              ],
            },
          },
          labels: {
            for (final key in procurementDocumentLabelKeys)
              key: procurementProcessLabel(key, language),
          },
          fontAsset: 'assets/fonts/PretendardVariable.ttf',
          printedAt: DateTime.utc(2026, 10, 13, 3),
        );
        final dir = Directory('/tmp/pos-procurement-20261013-pdf');
        await dir.create(recursive: true);
        await File(
          '${dir.path}/pr-two-stage-$language.pdf',
        ).writeAsBytes(bytes);
        expect(bytes, isNotEmpty);
      },
    );
    for (final kind in ['complete', 'discrepancy']) {
      for (final count in [1, 20, 200]) {
        test(
          '$kind receipt report with $count materials ($language)',
          () async {
            final bytes = await buildProcurementReceiptReportPdf(
              {
                'kind': kind,
                'data': {
                  'purchase_order_no': 'PO-RECEIPT-TEST',
                  'store_name': 'Test store',
                  'supplier_name': 'Nhà cung cấp thử',
                  'inspector_name': 'Test inspector',
                  'confirmed_at': '2026-10-13T03:00:00Z',
                  'delivery_cycle': 1,
                  'lines': List.generate(
                    count,
                    (i) => {
                      'product_code': 'RAW-${i + 1}',
                      'product_name': '김치 / Kim chi nguyên liệu dài ${i + 1}',
                      'unit': 'Thùng(박스)',
                      'ordered_quantity': 10,
                      'previous_quantity': 0,
                      'received_quantity': kind == 'complete' ? 10 : 7,
                      'cumulative_quantity': kind == 'complete' ? 10 : 7,
                      'shortage_quantity': kind == 'complete' ? 0 : 3,
                      'excess_quantity': 0,
                      'rejected_quantity': 0,
                      'reason': kind == 'complete' ? '' : 'Thiếu 3 thùng',
                    },
                  ),
                },
              },
              language: language,
              fontAsset: 'assets/fonts/PretendardVariable.ttf',
            );
            expect(bytes, isNotEmpty);
            final dir = Directory('/tmp/pos-procurement-20261013-pdf');
            await dir.create(recursive: true);
            await File(
              '${dir.path}/$kind-$count-$language.pdf',
            ).writeAsBytes(bytes);
          },
        );
      }
    }
  }
}
