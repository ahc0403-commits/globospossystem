import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/procurement/procurement_document_pdf.dart';
import 'package:globos_pos_system/features/procurement/procurement_process_labels.dart';
import 'package:globos_pos_system/features/procurement/procurement_request_lines.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'PR display groups codes, retains shortage priority and source identity',
    () {
      final source = <Map<String, dynamic>>[
        {'id': '4', 'product_code': 'MB004'},
        {'id': 'missing'},
        {'id': '3', 'product_code': 'WR099', 'product_code_snapshot': 'MB003'},
        {'id': '2', 'product_code': 'mb002'},
        {
          'id': 'carry',
          'product_code': 'ZZ001',
          'shortage_sources': [
            {'quantity_base': 1},
          ],
        },
        {'id': 'duplicate', 'product_code': 'MB003'},
        {'id': 'empty', 'product_code': ' '},
      ];
      final sorted = procurementSortedRequestLines(source);
      expect(sorted.map((l) => l['id']), [
        'carry',
        '2',
        '3',
        'duplicate',
        '4',
        'missing',
        'empty',
      ]);
      expect(source.map((l) => l['id']), [
        '4',
        'missing',
        '3',
        '2',
        'carry',
        'duplicate',
        'empty',
      ]);
      sorted.first['product_code'] = 'EDITED';
      expect(source[4]['product_code'], 'ZZ001');
    },
  );

  for (final locale in ['ko', 'en', 'vi']) {
    test(
      'sorted PR PDF hides submitted time and preserves fields ($locale)',
      () async {
        final data = <String, dynamic>{
          'request_no': 'PR-PREVIEW-20261022',
          'store_name': 'Example store / 매장 예시 / Cửa hàng mẫu',
          'created_at': '2026-10-22T01:00:00Z',
          'submitted_at': '2040-01-02T03:04:00Z',
          'requested_delivery_date': '2026-10-23',
          'approval_policy_version': 3,
          'status': 'office_review',
          'created_actor': {'display_name': 'Example requester'},
          'purchase_category': 'raw_material',
          'reason': 'Layout review',
          'lines': [
            for (final code in ['MB004', 'MB003', 'MB002', 'ZZ001'])
              {
                'id': code,
                'product_name': 'Example material',
                'product_code_snapshot': code,
                'requested_quantity': 2,
                'requested_unit': 'kg',
                'quantity_base': 2,
                'conversion_snapshot': 1,
                'current_stock_snapshot': 3,
                'estimated_conversion': 1,
                'estimated_unit_price': 10000,
                'estimated_tax_rate': 8,
                if (code == 'ZZ001')
                  'shortage_sources': [
                    {'quantity_base': 1, 'purchase_order_no': 'PO-PREVIOUS'},
                  ],
              },
          ],
        };
        final bytes = await buildProcurementDocumentPdf(
          {'kind': 'pr', 'audience': 'internal', 'data': data},
          labels: {
            for (final key in procurementDocumentLabelKeys)
              key: procurementProcessLabel(key, locale),
          },
          fontAsset: 'assets/fonts/PretendardVariable.ttf',
          printedAt: DateTime.utc(2026, 10, 22, 2),
        );
        final output = Directory(
          Platform.environment['PROCUREMENT_PDF_OUTPUT'] ??
              '/tmp/pos-improvement-20261022/pdf-pos',
        );
        await output.create(recursive: true);
        await File(
          '${output.path}/pr-improved-$locale.pdf',
        ).writeAsBytes(bytes);
        expect(data['submitted_at'], '2040-01-02T03:04:00Z');
        expect((data['lines'] as List).first['id'], 'MB004');
      },
    );
  }
}
