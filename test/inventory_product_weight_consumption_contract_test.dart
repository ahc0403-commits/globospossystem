import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('one 450g package loses only the 13g recipe quantity on sale', () {
    final productManagement = File(
      'supabase/migrations/20260506008000_inventory_product_management.sql',
    ).readAsStringSync();
    final supplierLink = File(
      'supabase/migrations/'
      '20260728005705_inventory_ingredient_supplier_link.sql',
    ).readAsStringSync();
    final recipeBaseUnit = File(
      'supabase/migrations/'
      '20260822120000_inventory_recipe_base_unit_import.sql',
    ).readAsStringSync();
    final payment = File(
      'supabase/migrations/20260707010000_service_item_exclusion_v1.sql',
    ).readAsStringSync();
    final paymentWrapper = File(
      'supabase/migrations/'
      '20260817110000_menu_scoped_promotion_integrity.sql',
    ).readAsStringSync();

    expect(
      productManagement,
      contains('base_unit_factor = p_base_unit_factor'),
    );
    expect(productManagement, contains('unit = v_base_unit'));
    expect(
      supplierLink,
      contains('p_order_unit_quantity_base := v_product.base_unit_factor'),
    );
    expect(recipeBaseUnit, contains("v_line->>'quantity_base'"));
    expect(
      recipeBaseUnit,
      contains('ingredient canonical base unit (g, ml, or ea)'),
    );
    expect(
      payment,
      contains('v_deduct_qty := v_item.ordered_qty * v_recipe.quantity_g;'),
    );
    expect(
      payment,
      isNot(contains('v_recipe.quantity_g * product.base_unit_factor')),
    );
    expect(
      paymentWrapper,
      contains('process_payment_without_scoped_promotions'),
    );

    const packageWeightG = 450.0;
    const recipeConsumptionG = 13.0;
    expect(packageWeightG - recipeConsumptionG, 437.0);
  });

  test('ingredient UI and Excel use purchase and consumption terminology', () {
    final korean = File('lib/l10n/app_ko.arb').readAsStringSync();
    final ingredientExcel = File(
      'lib/features/inventory/ingredient_excel_import.dart',
    ).readAsStringSync();

    expect(korean, contains('"inventoryPurchaseDisplayStockUnit": "구매 단위"'));
    expect(korean, contains('"inventoryPurchaseBaseUnit": "소진 단위"'));
    expect(korean, contains('제품중량 (구매단위당)'));
    expect(
      korean,
      contains('1 {purchaseUnit} = {productWeight} {consumptionUnit}'),
    );
    expect(ingredientExcel, contains("'구매단위'"));
    expect(ingredientExcel, contains("'소진단위'"));
    expect(ingredientExcel, contains("'제품중량'"));
    expect(ingredientExcel, contains("'재고표시단위'"));
    expect(ingredientExcel, contains("'표시단위환산수량'"));
  });
}
