import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recipe Excel import RPC is atomic and store-scoped', () {
    final sql = File(
      'supabase/migrations/20260724010000_inventory_recipe_excel_import.sql',
    ).readAsStringSync();

    expect(sql, contains('bulk_upsert_inventory_recipe_lines'));
    expect(sql, contains('can_access_inventory_purchase_store(p_store_id)'));
    expect(sql, contains('jsonb_array_length(p_lines)'));
    expect(sql, contains('ON CONFLICT (menu_item_id, ingredient_id)'));
    expect(sql, contains('INVENTORY_RECIPE_IMPORT_DUPLICATE'));
    expect(sql, contains('inventory_recipe_excel_imported'));
  });
}
