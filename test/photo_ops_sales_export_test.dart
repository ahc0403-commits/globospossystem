import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/photo_ops/photo_ops_sales_export.dart';

void main() {
  test('requires every legal-entity store to finish the 22:20 collection', () {
    const stores = [
      {'id': 'store-a'},
      {'id': 'store-b'},
    ];

    expect(
      () => validatePhotoOpsSalesExportReady(
        stores: stores,
        completedRuns: const [
          {'store_id': 'store-a'},
        ],
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'PHOTO_EXPORT_NOT_READY:1',
        ),
      ),
    );
    expect(
      () => validatePhotoOpsSalesExportReady(
        stores: stores,
        completedRuns: const [
          {'store_id': 'store-a'},
          {'store_id': 'store-b'},
        ],
      ),
      returnsNormally,
    );
  });

  test('builds one legal-entity export with receipt and hourly detail', () {
    final export = createPhotoOpsSalesExport(
      saleDate: '2026-07-16',
      stores: const [
        {'id': 'store-a', 'name': 'Photo A', 'tax_entity_id': 'tax-entity-1'},
        {'id': 'store-b', 'name': 'Photo B', 'tax_entity_id': 'tax-entity-1'},
      ],
      rawSales: const [
        {
          'id': 'sale-b',
          'store_id': 'store-b',
          'sold_at': '2026-07-16T12:05:00+07:00',
          'sale_time_text': '12:05:00',
          'device_name': 'B-01',
          'device_id': 'device-b',
          'amount': 150000,
          'raw_type': 'PHOTO',
          'payment_method': 'CASH',
          'source_hash': 'receipt-b',
        },
        {
          'id': 'sale-a',
          'store_id': 'store-a',
          'sold_at': '2026-07-16T10:10:00+07:00',
          'sale_time_text': '10:10:00',
          'device_name': 'A-01',
          'device_id': 'device-a',
          'amount': '100000',
          'raw_type': 'PHOTO',
          'payment_method': 'CASH',
          'source_hash': 'receipt-a',
        },
      ],
    );

    expect(export.taxEntityId, 'tax-entity-1');
    expect(export.storeCount, 2);
    expect(export.receiptCount, 2);
    expect(export.totalAmount, 250000);
    expect(export.receipts.map((row) => row.receiptId), [
      'receipt-a',
      'receipt-b',
    ]);
    expect(export.hourlyTotals['10:00-10:59']?.amount, 100000);
    expect(export.hourlyTotals['12:00-12:59']?.amount, 150000);

    final bytes = buildPhotoOpsSalesWorkbook(export);
    final workbook = Excel.decodeBytes(bytes);
    expect(workbook.tables.keys, containsAll(['Sales', 'Hourly Summary']));
    expect(
      workbook.tables['Sales']!.rows.first.first!.value.toString(),
      'Store',
    );
    expect(workbook.tables['Sales']!.rows.length, 3);
  });

  test('rejects exports that mix legal entities', () {
    expect(
      () => createPhotoOpsSalesExport(
        saleDate: '2026-07-16',
        stores: const [
          {'id': 'store-a', 'name': 'A', 'tax_entity_id': 'tax-1'},
          {'id': 'store-b', 'name': 'B', 'tax_entity_id': 'tax-2'},
        ],
        rawSales: const [],
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'PHOTO_EXPORT_MULTIPLE_TAX_ENTITIES',
        ),
      ),
    );
  });

  test('rejects malformed receipt rows instead of silently omitting sales', () {
    expect(
      () => createPhotoOpsSalesExport(
        saleDate: '2026-07-16',
        stores: const [
          {'id': 'store-a', 'name': 'A', 'tax_entity_id': 'tax-1'},
        ],
        rawSales: const [
          {
            'id': 'sale-a',
            'store_id': 'store-a',
            'sold_at': 'invalid',
            'amount': 100000,
            'source_hash': 'receipt-a',
          },
        ],
      ),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          contains('PHOTO_EXPORT_INVALID_SOLD_AT'),
        ),
      ),
    );
  });
}
