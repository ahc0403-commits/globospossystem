import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export.dart';

void main() {
  test('builds one finalized legal-entity workbook with receipt times', () {
    final export = createRestaurantSalesExport({
      'business_date': '2026-07-16',
      'status': 'finalized',
      'store_count': 2,
      'receipt_count': 2,
      'gross_sales': '250000.00',
      'finalized_at': '2026-07-16T22:20:00+07:00',
      'receipts': [
        {
          'store_id': 'store-b',
          'store_name': 'Restaurant B',
          'receipt_id': 'receipt-b',
          'receipt_source': 'external_delivery',
          'sales_channel': 'delivery',
          'gross_sales': '150000.00',
          'sold_at': '2026-07-16T12:05:00+07:00',
        },
        {
          'store_id': 'store-a',
          'store_name': 'Restaurant A',
          'receipt_id': 'receipt-a',
          'receipt_source': 'pos_payment',
          'sales_channel': 'dine_in',
          'gross_sales': 100000,
          'sold_at': '2026-07-16T10:10:00+07:00',
        },
      ],
    });

    expect(export.businessDate, '2026-07-16');
    expect(export.storeCount, 2);
    expect(export.receiptCount, 2);
    expect(export.grossSales, 250000);
    expect(export.receipts.map((row) => row.receiptId), [
      'receipt-a',
      'receipt-b',
    ]);
    expect(export.hourlyTotals['10:00-10:59']?.grossSales, 100000);
    expect(export.hourlyTotals['12:00-12:59']?.grossSales, 150000);

    final bytes = buildRestaurantSalesWorkbook(export);
    final workbook = Excel.decodeBytes(bytes);
    expect(
      workbook.tables.keys,
      containsAll(['Sales', 'Hourly Summary', 'Summary']),
    );
    expect(workbook.tables['Sales']!.rows.length, 3);
    expect(
      workbook.tables['Sales']!.rows.first.first!.value.toString(),
      'Store',
    );
  });

  test('refuses pending and integrity-failed finalizations', () {
    expect(
      () => createRestaurantSalesExport({
        'business_date': '2026-07-16',
        'status': 'pending',
        'receipts': const [],
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'RESTAURANT_EXPORT_NOT_READY',
        ),
      ),
    );
    expect(
      () => createRestaurantSalesExport({
        'business_date': '2026-07-16',
        'status': 'data_integrity_failed',
        'receipts': const [],
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'RESTAURANT_EXPORT_DATA_INTEGRITY_FAILED',
        ),
      ),
    );
  });

  test('rejects partial or altered finalized receipt data', () {
    expect(
      () => createRestaurantSalesExport({
        'business_date': '2026-07-16',
        'status': 'finalized',
        'store_count': 1,
        'receipt_count': 2,
        'gross_sales': 100000,
        'finalized_at': '2026-07-16T22:20:00+07:00',
        'receipts': [
          {
            'store_id': 'store-a',
            'store_name': 'Restaurant A',
            'receipt_id': 'receipt-a',
            'receipt_source': 'pos_payment',
            'sales_channel': 'dine_in',
            'gross_sales': 100000,
            'sold_at': '2026-07-16T10:10:00+07:00',
          },
        ],
      }),
      throwsA(
        isA<FormatException>().having(
          (error) => error.message,
          'message',
          'RESTAURANT_EXPORT_RECEIPT_COUNT_MISMATCH',
        ),
      ),
    );
  });
}
