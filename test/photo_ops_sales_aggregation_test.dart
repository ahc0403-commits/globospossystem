import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/photo_ops/photo_ops_service.dart';

void main() {
  test('Photo Ops uses the Asia Ho Chi Minh calendar day', () {
    expect(
      photoOpsHcmDate(DateTime.parse('2026-07-10T18:30:00Z')),
      '2026-07-11',
    );
  });

  test('Photo Ops aggregates range sales by active and accessible stores', () {
    final snapshot = summarizePhotoOpsSales(
      activeStoreId: 'store-a',
      rows: const [
        {
          'store_id': 'store-a',
          'store_name': 'Store A',
          'sale_date': '2026-07-11',
          'total_gross_sales': '120000',
          'total_transactions': 3,
          'total_service_amount': 10000,
          'active_machines': 2,
          'last_pulled_at': '2026-07-11T08:00:00Z',
        },
        {
          'store_id': 'store-b',
          'store_name': 'Store B',
          'sale_date': '2026-07-11',
          'total_gross_sales': 80000,
          'total_transactions': '2',
          'total_service_amount': '0',
          'active_machines': '1',
          'last_pulled_at': '2026-07-11T09:00:00Z',
        },
        {
          'store_id': 'store-a',
          'store_name': 'Store A',
          'sale_date': '2026-07-10',
          'total_gross_sales': 30000,
          'total_transactions': 1,
          'total_service_amount': 0,
          'active_machines': 1,
          'last_pulled_at': '2026-07-10T09:00:00Z',
        },
      ],
    );

    expect(snapshot.activeStoreSales, 150000);
    expect(snapshot.networkSales, 230000);
    expect(snapshot.activeStoreTransactions, 4);
    expect(snapshot.lastSalesPulledAt, DateTime.parse('2026-07-11T09:00:00Z'));
    expect(snapshot.rows.map((row) => row.storeName), [
      'Store A',
      'Store B',
      'Store A',
    ]);
  });

  test('Photo Ops ignores malformed rows and safely parses invalid totals', () {
    final snapshot = summarizePhotoOpsSales(
      activeStoreId: 'store-a',
      rows: const [
        {
          'store_id': '',
          'store_name': 'Missing store',
          'sale_date': '2026-07-11',
          'total_gross_sales': 999999,
        },
        {
          'store_id': 'store-a',
          'store_name': 'Invalid date',
          'sale_date': 'not-a-date',
          'total_gross_sales': 999999,
        },
        {
          'store_id': 'store-a',
          'store_name': 'Store A',
          'sale_date': '2026-07-11',
          'total_gross_sales': 'not-a-number',
          'total_transactions': null,
          'total_service_amount': null,
          'active_machines': null,
          'last_pulled_at': 'invalid',
        },
      ],
    );

    expect(snapshot.rows, hasLength(1));
    expect(snapshot.activeStoreSales, 0);
    expect(snapshot.networkSales, 0);
    expect(snapshot.activeStoreTransactions, 0);
    expect(snapshot.lastSalesPulledAt, isNull);
  });
}
