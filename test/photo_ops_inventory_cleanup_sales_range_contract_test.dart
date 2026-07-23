import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260723070000_photo_ops_inventory_cleanup_sales_range.sql';

  test('removes only the known Photo Objet restaurant inventory seed', () {
    final migration = File(migrationPath).readAsStringSync();

    expect(migration, contains("'77000000-0000-0000-0000-000000000001'::uuid"));
    expect(migration, contains("'2026-05-06 09:00:57.334069+00'::timestamptz"));
    expect(migration, contains("'2026-05-06 09:06:00.256853+00'::timestamptz"));
    expect(migration, contains('v_item_count <> 48'));
    expect(migration, contains('v_product_count <> 48'));
    expect(migration, contains('DELETE FROM public.inventory_products'));
    expect(migration, contains('DELETE FROM public.inventory_items'));
    expect(migration, contains('DELETE FROM public.inventory_suppliers'));
  });

  test('sales range is inclusive and permission scoped', () {
    final migration = File(migrationPath).readAsStringSync();
    final provider = File(
      'lib/features/photo_ops/photo_ops_provider.dart',
    ).readAsStringSync();
    final screen = File(
      'lib/features/photo_ops/photo_ops_screen.dart',
    ).readAsStringSync();

    expect(migration, contains('p_start_date date'));
    expect(migration, contains('p_end_date date'));
    expect(
      migration,
      contains('s.sale_date BETWEEN p_start_date AND p_end_date'),
    );
    expect(migration, contains('user_accessible_stores(auth.uid())'));
    expect(provider, contains('setSalesDateRange'));
    expect(screen, contains("Key('photo_ops_sales_date_range_button')"));
    expect(screen, contains('showDateRangePicker'));
  });
}
