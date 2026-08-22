import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/production_gate_test_support.dart';

void main() {
  test('recipe import supports every canonical inventory base unit', () {
    final migration = File(
      'supabase/migrations/'
      '20260822100000_inventory_recipe_base_unit_import.sql',
    ).readAsStringSync();
    final preflight = File(
      'scripts/preflight_inventory_recipe_base_unit_import.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_inventory_recipe_base_unit_import.sql',
    ).readAsStringSync();

    expect(migration, contains("product.base_unit IN ('g', 'ml', 'ea')"));
    expect(migration, contains("v_ingredient_unit NOT IN ('g', 'ml', 'ea')"));
    expect(migration, contains("v_line->>'quantity_base'"));
    expect(migration, contains('INVENTORY_RECIPE_INGREDIENT_UNIT_MISMATCH'));
    expect(migration, isNot(contains("ingredient.unit <> 'g'")));
    expect(migration, contains('create_inventory_menu_with_recipe'));
    expect(migration, contains('ingredient canonical base unit'));
    expect(preflight, contains('INVENTORY_RECIPE_BASE_UNIT_CONFLICT'));
    expect(verification, contains('INVENTORY_RECIPE_BASE_UNIT_SYNC_FAILED'));
  });

  test('production gate discovers recipe base-unit preflight and verify', () {
    final contract = readProductionGateContract();

    expect(
      contract,
      contains('20260822100000_inventory_recipe_base_unit_import.sql'),
    );
    expect(
      contract,
      contains('preflight_inventory_recipe_base_unit_import.sql'),
    );
    expect(contract, contains('verify_inventory_recipe_base_unit_import.sql'));
  });
}
