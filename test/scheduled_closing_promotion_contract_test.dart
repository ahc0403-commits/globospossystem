import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final migration = File(
    'supabase/migrations/20260804010000_scheduled_closing_and_promotions.sql',
  );
  final deploy = File('scripts/deploy_pos_production.sh');

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
    expect(sql, contains("'current_stock', COALESCE(i.current_stock, i.quantity, 0)"));
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

  test('production deployment has explicit preflight and verification gates', () {
    final script = deploy.readAsStringSync();
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
    expect(
      script,
      contains('verify_scheduled_closing_and_promotions.sql'),
    );
    expect(verification, contains('END;\n\$verify\$;'));
  });
}
