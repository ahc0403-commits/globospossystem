import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ingredient Excel supplier price import has a production gate', () {
    final migration = File(
      'supabase/migrations/'
      '20260821090000_inventory_excel_supplier_price.sql',
    ).readAsStringSync();
    final preflight = File(
      'scripts/preflight_inventory_excel_supplier_price.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_inventory_excel_supplier_price.sql',
    ).readAsStringSync();

    expect(
      migration,
      contains("v_supplier_id := (v_row->>'supplier_id')::uuid"),
    );
    expect(migration, contains("v_unit_price := (v_row->>'unit_price')"));
    expect(migration, contains('public.upsert_inventory_supplier_item('));
    expect(migration, contains('p_unit_price := v_unit_price'));
    expect(migration, contains('p_is_preferred := TRUE'));
    expect(
      migration,
      contains('Validate every row before performing any mutation'),
    );
    expect(preflight, contains('bulk_upsert_inventory_ingredients'));
    expect(preflight, contains('upsert_inventory_supplier_item'));
    expect(verification, contains('INVENTORY_INGREDIENT_SUPPLIER_REQUIRED'));
    expect(verification, contains('INVENTORY_INGREDIENT_PRICE_INVALID'));
  });
}
