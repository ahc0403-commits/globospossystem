import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('ingredient registration persists and displays supplier links', () {
    final screen = File(
      'lib/features/inventory_purchase/inventory_purchase_screen.dart',
    ).readAsStringSync();
    final service = File(
      'lib/core/services/inventory_service.dart',
    ).readAsStringSync();
    final provider = File(
      'lib/features/inventory/inventory_provider.dart',
    ).readAsStringSync();
    final migration = File(
      'supabase/migrations/'
      '20260728005705_inventory_ingredient_supplier_link.sql',
    ).readAsStringSync();

    expect(screen, contains('inventory_product_primary_supplier_field'));
    expect(screen, contains('inventory_product_supplier_sku_field'));
    expect(screen, contains('.saveProductWithSupplier('));
    expect(screen, contains('supplierNames'));
    expect(service, contains("'upsert_inventory_product_with_supplier'"));
    expect(provider, contains('Future<bool> saveProductWithSupplier'));
    expect(migration, contains('p_supplier_id UUID'));
    expect(migration, contains('public.upsert_inventory_product('));
    expect(migration, contains('public.upsert_inventory_supplier_item('));
    expect(migration, contains('p_is_preferred := TRUE'));
    expect(migration, contains('auth.uid() IS NULL'));
    expect(migration, contains('REVOKE ALL ON FUNCTION'));
  });
}
