import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
    'ingredient Excel can atomically create and link a supplier by name',
    () {
      final migration = File(
        'supabase/migrations/'
        '20260821120000_inventory_excel_supplier_creation.sql',
      ).readAsStringSync();
      final preflight = File(
        'scripts/preflight_inventory_excel_supplier_creation.sql',
      ).readAsStringSync();
      final verification = File(
        'scripts/verify_inventory_excel_supplier_creation.sql',
      ).readAsStringSync();

      expect(migration, contains("v_row->>'supplier_name'"));
      expect(migration, contains('v_existing_supplier_name'));
      expect(
        migration,
        contains(
          'Cached clients from the supplier-price release sent only the id',
        ),
      );
      expect(migration, contains('INVENTORY_INGREDIENT_SUPPLIER_AMBIGUOUS'));
      expect(migration, contains('public.upsert_inventory_supplier('));
      expect(migration, contains('pg_advisory_xact_lock('));
      expect(migration, contains("'supplier_created_count'"));
      expect(migration, contains('public.upsert_inventory_supplier_item('));
      expect(migration, contains('p_unit_price := v_unit_price'));
      expect(
        migration,
        contains('Validate every row before performing any mutation'),
      );
      expect(preflight, contains('upsert_inventory_supplier'));
      expect(verification, contains('v_existing_supplier_name'));
      expect(verification, contains('supplier_created_count'));
    },
  );
}
