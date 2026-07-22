import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/models/pos_table.dart';

void main() {
  test('operational table changes are published to Supabase Realtime', () {
    final migration = File(
      'supabase/migrations/20260722110000_cashier_table_realtime_status.sql',
    ).readAsStringSync();

    for (final table in ['tables', 'orders', 'order_items', 'payments']) {
      expect(migration, contains("'$table'"));
    }
    expect(
      migration,
      contains('ALTER PUBLICATION supabase_realtime ADD TABLE'),
    );
    expect(migration, contains('pg_publication_tables'));
  });

  test('active order previews make a table operationally occupied', () {
    const table = PosTable(
      id: 'table-208',
      storeId: 'store-a',
      tableNumber: '208',
      seatCount: 4,
      status: 'available',
    );
    final occupied = table.copyWithStatus('occupied');

    expect(table.isAvailable, isTrue);
    expect(occupied.isOccupied, isTrue);
    expect(occupied.tableNumber, table.tableNumber);

    final provider = File(
      'lib/features/table/table_provider.dart',
    ).readAsStringSync();
    expect(provider, contains('orderPreviewByTableId.containsKey(table.id)'));
    expect(provider, contains("table.copyWithStatus('occupied')"));
  });
}
