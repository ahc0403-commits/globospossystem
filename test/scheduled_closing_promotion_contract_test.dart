import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/production_gate_test_support.dart';

void main() {
  final migration = File(
    'supabase/migrations/20260804010000_scheduled_closing_and_promotions.sql',
  );
  final scopedMigration = File(
    'supabase/migrations/20260817110000_menu_scoped_promotion_integrity.sql',
  );
  final deploy = readProductionGateContract();

  test('daily close is an idempotent 23:00 Ho Chi Minh snapshot', () {
    final sql = migration.readAsStringSync();

    expect(sql, contains('run_scheduled_daily_closings'));
    expect(sql, contains("AT TIME ZONE 'Asia/Ho_Chi_Minh'"));
    expect(
      sql,
      contains('ON CONFLICT (restaurant_id, closing_date) DO NOTHING'),
    );
    expect(sql, contains("'scheduled'"));
    expect(sql, contains('inventory_snapshot jsonb'));
    expect(
      sql,
      contains("'current_stock', COALESCE(i.current_stock, i.quantity, 0)"),
    );
    expect(sql, contains("'daily-closing-2300-hcm'"));
    expect(sql, contains("'0 16 * * *'"));
    expect(sql, contains('Automatic 23:00 Asia/Ho_Chi_Minh close'));
  });

  test('scheduled promotions are store scoped and auditable', () {
    final sql = migration.readAsStringSync();

    expect(sql, contains('CREATE TABLE IF NOT EXISTS public.store_promotions'));
    expect(sql, contains('PROMOTION_PERIOD_OVERLAP'));
    expect(sql, contains('public.user_accessible_stores(auth.uid())'));
    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.upsert_store_promotion'),
    );
    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.sync_active_order_promotion'),
    );
    expect(sql, contains("'scheduled_promotion'"));
    expect(sql, contains("v_existing.approved_via <> 'scheduled_promotion'"));
    expect(sql, contains('CREATE TRIGGER trg_sync_order_promotion'));
    expect(sql, contains('refresh_store_order_promotions'));
  });

  test('QR catalogue exposes original and scheduled promotional prices', () {
    final sql = migration.readAsStringSync();

    expect(sql, contains('CREATE OR REPLACE FUNCTION public.qr_get_menu'));
    expect(sql, contains("'original_price', mi.price"));
    expect(sql, contains("'discount_percent'"));
    expect(sql, contains("'promotion_name', v_promotion.name"));
    expect(sql, contains("p.channel IN ('both', 'qr')"));
  });

  test('menu-scoped promotions persist exact order-line allocations', () {
    final sql = scopedMigration.readAsStringSync();

    expect(sql, contains('store_promotions_scope_check'));
    expect(sql, contains('public.store_promotion_menu_items'));
    expect(sql, contains('public.order_discount_lines'));
    expect(sql, contains('PROMOTION_ALLOCATION_MISMATCH'));
    expect(sql, contains('process_payment_without_scoped_promotions'));
    expect(sql, contains("v_promo.scope = 'all_menu'"));
  });

  test('effective combo QR catalogue discounts only targeted menus', () {
    final sql = scopedMigration.readAsStringSync();

    expect(sql, contains('CREATE OR REPLACE FUNCTION public.qr_get_menu'));
    expect(sql, contains("v_promotion.scope = 'selected_items'"));
    expect(sql, contains('public.combo_drink_choice_count(menu.id)'));
    expect(sql, contains('public.combo_drink_options(menu.id)'));
  });

  test(
    'production deployment has explicit preflight and verification gates',
    () {
      final script = deploy;
      final verification = File(
        'scripts/verify_scheduled_closing_and_promotions.sql',
      ).readAsStringSync();

      expect(
        script,
        contains('20260804010000_scheduled_closing_and_promotions.sql'),
      );
      expect(
        script,
        contains('preflight_scheduled_closing_and_promotions.sql'),
      );
      expect(script, contains('verify_scheduled_closing_and_promotions.sql'));
      expect(verification, contains('END;\n\$verify\$;'));
    },
  );
}
