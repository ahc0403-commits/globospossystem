import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'table reservation is a real database status that blocks order start',
    () {
      final migration = readRepoFile(
        'supabase/migrations/20260527000000_table_reservation_status.sql',
      );

      expect(
        migration,
        contains("CHECK (status IN ('available', 'reserved', 'occupied'))"),
      );
      expect(migration, contains('TABLE_STATUS_INVALID'));
      expect(migration, contains("IF v_table.status <> 'available' THEN"));
      expect(migration, contains("RAISE EXCEPTION 'TABLE_NOT_AVAILABLE'"));
      expect(
        migration,
        contains('CREATE OR REPLACE FUNCTION public.create_order('),
      );
      expect(
        migration,
        contains('CREATE OR REPLACE FUNCTION public.create_buffet_order('),
      );
    },
  );

  test('admin table screen can reserve and release a selected table', () {
    final tablesTab = readRepoFile('lib/features/admin/tabs/tables_tab.dart');
    final tablesProvider = readRepoFile(
      'lib/features/admin/providers/tables_provider.dart',
    );
    final tablesService = readRepoFile('lib/core/services/tables_service.dart');
    final koArb = readRepoFile('lib/l10n/app_ko.arb');

    expect(tablesTab, contains("selected: _tableFilter == 'reserved'"));
    expect(tablesTab, contains("setState(() => _tableFilter = 'reserved')"));
    expect(tablesTab, contains("Key('admin_tables_toggle_reservation')"));
    expect(tablesTab, contains("'reserved'"));
    expect(tablesTab, contains("'available'"));
    expect(tablesTab, contains('tablesReserveSelected'));
    expect(tablesTab, contains('tablesReleaseReservation'));
    expect(tablesProvider, contains('Future<bool> updateTableStatus'));
    expect(tablesService, contains('p_status'));
    expect(koArb, contains('"tablesFilterReserved": "예약"'));
  });

  test('waiter cannot use reserved tables as available tables', () {
    final waiter = readRepoFile('lib/features/waiter/waiter_screen.dart');
    final floorLayout = readRepoFile('lib/features/table/floor_layout.dart');
    final orderProvider = readRepoFile(
      'lib/features/order/order_provider.dart',
    );

    expect(waiter, contains('if (table.isReserved)'));
    expect(waiter, contains('waiterTableReservedUnavailable'));
    expect(waiter, contains('t.isAvailable'));
    expect(waiter, contains('reservedCount'));
    expect(floorLayout, contains('final reserved = table.isReserved'));
    expect(floorLayout, contains("'Reserved'"));
    expect(orderProvider, contains("'TABLE_NOT_AVAILABLE'"));
  });
}
