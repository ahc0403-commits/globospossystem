import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/'
      '20260724040704_inventory_daily_stock_history.sql';

  test('daily inventory saves dated snapshots and immutable adjustments', () {
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains('ADD COLUMN IF NOT EXISTS stock_before'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS stock_after'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS effective_date'));
    expect(sql, contains('ADD COLUMN IF NOT EXISTS note text'));
    expect(sql, contains('save_photo_objet_daily_inventory_item'));
    expect(sql, contains('upsert_photo_objet_inventory_item'));
    expect(sql, contains("'Legacy current-stock save'"));
    expect(sql, contains('SECURITY INVOKER'));
    expect(sql, contains('apply_inventory_physical_count_line'));
    expect(sql, contains('get_inventory_stock_adjustment_history'));
    expect(sql, contains('inventory_daily_stock_saved'));
    expect(sql, contains("'Asia/Ho_Chi_Minh'"));
    expect(sql, contains('stock_before'));
    expect(sql, contains('stock_after'));
    expect(sql, contains('p_count_date'));
    expect(sql, contains('p_count_date = v_hcm_today'));
  });

  test('inventory history RPCs enforce role, store scope, and grants', () {
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains('public.user_accessible_stores(auth.uid())'));
    expect(sql, contains("'photo_objet_master'"));
    expect(sql, contains("'store_admin'"));
    expect(sql, contains("'brand_admin'"));
    expect(sql, contains('FROM PUBLIC, anon, authenticated, service_role'));
    expect(sql, contains('TO authenticated'));
    expect(sql, contains('SET search_path = public, auth, pg_catalog'));
    expect(sql, isNot(contains('TO anon')));
  });

  test('Photo inventory client records date and exposes history', () {
    final service = File(
      'lib/core/services/inventory_service.dart',
    ).readAsStringSync();
    final screen = File(
      'lib/features/photo_inventory/photo_inventory_screen.dart',
    ).readAsStringSync();

    expect(service, contains("'save_photo_objet_daily_inventory_item'"));
    expect(service, contains("'get_inventory_stock_adjustment_history'"));
    expect(service, contains("'p_count_date'"));
    expect(screen, contains("Key('photo_inventory_count_date')"));
    expect(screen, contains("Key('photo_inventory_history')"));
    expect(screen, contains("Key('photo_inventory_history_dialog')"));
    expect(screen, contains('inventoryHistoryQuantityChange'));
  });

  test('daily inventory migration is production-gated', () {
    final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();
    final preflight = File(
      'scripts/preflight_inventory_daily_stock_history.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_inventory_daily_stock_history.sql',
    ).readAsStringSync();

    expect(
      deploy,
      contains('20260724040704_inventory_daily_stock_history.sql'),
    );
    expect(deploy, contains('preflight_inventory_daily_stock_history.sql'));
    expect(deploy, contains('verify_inventory_daily_stock_history.sql'));
    expect(preflight, contains('inventory physical-count daily uniqueness'));
    expect(verification, contains('inventory daily stock verification passed'));
  });
}
