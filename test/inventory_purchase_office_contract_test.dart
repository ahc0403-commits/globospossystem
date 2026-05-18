import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migrationPath =
      'supabase/migrations/20260506000000_inventory_purchase_office_contracts.sql';
  const bootstrapSeedPath =
      'supabase/migrations/20260506001000_inventory_purchase_bootstrap_seed.sql';
  const accessFixPath =
      'supabase/migrations/20260506002000_inventory_purchase_pos_native_access_fix.sql';
  const receiptObservabilityPath =
      'supabase/migrations/20260513010000_inventory_receiving_idempotency_observability.sql';
  const recommendationAdjustmentPath =
      'supabase/migrations/20260515090000_inventory_recommendation_adjustments.sql';

  test(
    'inventory purchase migration defines separate Office-reviewable domain',
    () {
      final migrationFile = File(migrationPath);

      expect(migrationFile.existsSync(), isTrue);

      final sql = readRepoFile(migrationPath);

      expect(
        sql,
        contains('CREATE TABLE IF NOT EXISTS public.inventory_suppliers'),
      );
      expect(
        sql,
        contains('CREATE TABLE IF NOT EXISTS public.inventory_products'),
      );
      expect(
        sql,
        contains('CREATE TABLE IF NOT EXISTS public.inventory_supplier_items'),
      );
      expect(
        sql,
        contains('CREATE TABLE IF NOT EXISTS public.inventory_purchase_orders'),
      );
      expect(
        sql,
        contains(
          'CREATE TABLE IF NOT EXISTS public.inventory_purchase_order_lines',
        ),
      );
      expect(
        sql,
        contains('CREATE TABLE IF NOT EXISTS public.inventory_receipts'),
      );
      expect(
        sql,
        contains('CREATE TABLE IF NOT EXISTS public.inventory_receipt_lines'),
      );
      expect(
        sql,
        contains(
          'CREATE TABLE IF NOT EXISTS public.inventory_daily_consumption',
        ),
      );
      expect(
        sql,
        contains(
          'CREATE TABLE IF NOT EXISTS public.inventory_recommendation_runs',
        ),
      );
      expect(
        sql,
        contains(
          'CREATE TABLE IF NOT EXISTS public.inventory_recommendation_lines',
        ),
      );
      expect(
        sql,
        contains(
          'CREATE TABLE IF NOT EXISTS public.inventory_stock_audit_sessions',
        ),
      );
      expect(
        sql,
        contains(
          'CREATE TABLE IF NOT EXISTS public.inventory_stock_audit_lines',
        ),
      );

      expect(
        sql,
        contains(
          "CHECK (status IN ('draft', 'submitted', 'office_approved', 'office_returned', 'office_rejected', 'ordered', 'partially_received', 'received', 'cancelled'))",
        ),
      );
      expect(sql, contains('order_unit_quantity_base'));
      expect(sql, contains('recommendation_snapshot JSONB'));
      expect(
        sql,
        contains(
          'ALTER TABLE public.inventory_purchase_orders ENABLE ROW LEVEL SECURITY',
        ),
      );
      expect(sql, contains('public.user_accessible_stores(auth.uid())'));
      expect(sql, contains("auth.role() = 'service_role'"));
      expect(sql, isNot(contains('office_user_profiles')));

      expect(sql, isNot(contains('office_purchases')));
      expect(sql, isNot(contains('accounting.purchase_requests')));
    },
  );

  test(
    'inventory purchase migration includes weighted consumption recommendation contracts',
    () {
      final migrationFile = File(migrationPath);

      expect(migrationFile.existsSync(), isTrue);

      final sql = readRepoFile(migrationPath);

      expect(
        sql,
        contains(
          'CREATE OR REPLACE FUNCTION public.get_inventory_purchase_dashboard',
        ),
      );
      expect(
        sql,
        contains(
          'CREATE OR REPLACE FUNCTION public.get_inventory_stock_status',
        ),
      );
      expect(
        sql,
        contains(
          'CREATE OR REPLACE FUNCTION public.run_inventory_purchase_recommendation',
        ),
      );
      expect(
        sql,
        contains(
          'CREATE OR REPLACE FUNCTION public.create_purchase_orders_from_recommendation',
        ),
      );
      expect(sql, contains('recent_4_day_avg'));
      expect(sql, contains('recent_7_day_avg'));
      expect(sql, contains('recent_4_day_avg * 0.7 + recent_7_day_avg * 0.3'));
      expect(sql, contains('CEIL('));
      expect(
        sql,
        contains("risk_status IN ('danger', 'warning', 'normal', 'stable')"),
      );
    },
  );

  test('inventory purchase migration exposes Office approval and edit RPCs', () {
    final migrationFile = File(migrationPath);

    expect(migrationFile.existsSync(), isTrue);

    final sql = readRepoFile(migrationPath);

    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.office_get_inventory_purchase_orders',
      ),
    );
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.office_get_inventory_purchase_order_detail',
      ),
    );
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.office_update_inventory_purchase_order',
      ),
    );
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.office_approve_inventory_purchase_order',
      ),
    );
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.office_return_inventory_purchase_order',
      ),
    );
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.office_reject_inventory_purchase_order',
      ),
    );
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.office_cancel_inventory_purchase_order',
      ),
    );

    expect(sql, contains("status = 'office_approved'"));
    expect(sql, contains("status = 'office_returned'"));
    expect(sql, contains("status = 'office_rejected'"));
    expect(sql, contains('INVENTORY_PURCHASE_OFFICE_FORBIDDEN'));
    expect(sql, contains('INVENTORY_PURCHASE_NOT_EDITABLE'));
  });

  test('inventory purchase bootstrap seed is idempotent and scoped', () {
    final seedFile = File(bootstrapSeedPath);

    expect(seedFile.existsSync(), isTrue);

    final sql = readRepoFile(bootstrapSeedPath);

    expect(sql, contains('inventory_suppliers'));
    expect(sql, contains('inventory_products'));
    expect(sql, contains('inventory_supplier_items'));
    expect(sql, contains('inventory_daily_consumption'));
    expect(sql, contains('inventory_stock_audit_sessions'));
    expect(sql, contains('WHERE NOT EXISTS'));
    expect(sql, contains('public.restaurants'));
    expect(sql, isNot(contains('office_purchases')));
    expect(sql, isNot(contains('accounting.purchase_requests')));
  });

  test('inventory purchase access helpers stay POS-native', () {
    final accessFixFile = File(accessFixPath);

    expect(accessFixFile.existsSync(), isTrue);

    final sql = readRepoFile(accessFixPath);

    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.can_access_inventory_purchase_store',
      ),
    );
    expect(sql, contains('public.user_accessible_stores(auth.uid())'));
    expect(sql, contains("auth.role() = 'service_role'"));
    expect(sql, isNot(contains('office_user_profiles')));
  });

  test('inventory purchase supplier reads are tenant scoped', () {
    final sql = readRepoFile(migrationPath);

    expect(sql, contains('inventory_suppliers_scoped_read'));
    expect(sql, contains('inventory_supplier_items_scoped_read'));
    expect(
      sql,
      isNot(contains('CREATE POLICY inventory_suppliers_authenticated_read')),
    );
    expect(
      sql,
      isNot(
        contains('CREATE POLICY inventory_supplier_items_authenticated_read'),
      ),
    );
    expect(sql, isNot(contains('USING (auth.uid() IS NOT NULL)')));
  });

  test(
    'inventory purchase dashboard counts low stock across all scoped stores',
    () {
      final sql = readRepoFile(migrationPath);

      expect(
        sql,
        contains('CROSS JOIN LATERAL public.get_inventory_stock_status'),
      );
      expect(
        sql,
        isNot(contains('COALESCE(p_store_id, v_scope_store_ids[1])')),
      );
    },
  );

  test('inventory purchase line edits recalculate totals by order unit', () {
    final sql = readRepoFile(
      'supabase/migrations/20260506003000_inventory_purchase_line_amount_fix.sql',
    );

    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.office_update_inventory_purchase_order',
      ),
    );
    expect(sql, contains('v_ordered_quantity_unit'));
    expect(
      sql,
      contains('v_ordered_quantity_unit * v_existing_line.unit_price'),
    );
    expect(
      sql,
      isNot(contains('v_ordered_quantity_base * v_existing_line.unit_price')),
    );
  });

  test('inventory purchase receipt confirmation updates stock on receipt only', () {
    final sql = readRepoFile(
      'supabase/migrations/20260506004000_inventory_purchase_receipt_confirm.sql',
    );

    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.confirm_inventory_purchase_receipt',
      ),
    );
    expect(sql, contains('INSERT INTO public.inventory_receipts'));
    expect(sql, contains('INSERT INTO public.inventory_receipt_lines'));
    expect(sql, contains('UPDATE public.inventory_items'));
    expect(sql, contains('current_stock = COALESCE(current_stock, 0) +'));
    expect(sql, contains('INSERT INTO public.inventory_transactions'));
    expect(sql, contains("'restock'"));
    expect(sql, contains("THEN 'received'"));
    expect(sql, contains("ELSE 'partially_received'"));
    expect(
      sql,
      contains(
        "v_order.status NOT IN ('office_approved', 'ordered', 'partially_received')",
      ),
    );
  });

  test('inventory receiving idempotency and observability stay backend-owned', () {
    final sql = readRepoFile(receiptObservabilityPath);

    expect(
      sql,
      contains(
        'CREATE TABLE IF NOT EXISTS public.inventory_receipt_confirmation_attempts',
      ),
    );
    expect(sql, contains('UNIQUE (purchase_order_id, attempt_key)'));
    expect(
      sql,
      contains(
        "hashtext('confirm_inventory_purchase_receipt:' || p_purchase_order_id::TEXT || ':' || v_attempt_key_normalized)",
      ),
    );
    expect(
      sql,
      contains("attempt_status IN ('succeeded', 'replayed', 'noop')"),
    );
    expect(sql, contains("'replayed'"));
    expect(sql, contains("'succeeded'"));
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.get_inventory_receipt_attempt_trace',
      ),
    );
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.get_inventory_receiving_operational_observability',
      ),
    );
    expect(
      sql,
      contains(
        'GRANT EXECUTE ON FUNCTION public.confirm_inventory_purchase_receipt(UUID, TEXT, JSONB) TO authenticated',
      ),
    );
    expect(sql, isNot(contains('office_approve_inventory_purchase_order')));
    expect(
      sql,
      isNot(contains("rpc('office_approve_inventory_purchase_order'")),
    );
    expect(sql, isNot(contains("from('payments')")));
    expect(sql, isNot(contains("from('orders')")));
    expect(sql, isNot(contains("from('tables')")));
  });

  test('inventory purchase stock audit save supports draft before completion', () {
    final sql = readRepoFile(
      'supabase/migrations/20260506005000_inventory_purchase_stock_audit_save.sql',
    );

    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.save_inventory_stock_audit'),
    );
    expect(sql, contains('p_complete BOOLEAN DEFAULT FALSE'));
    expect(sql, contains('INSERT INTO public.inventory_stock_audit_sessions'));
    expect(sql, contains('INSERT INTO public.inventory_stock_audit_lines'));
    expect(sql, contains('UPDATE public.inventory_items'));
    expect(sql, contains('IF COALESCE(p_complete, FALSE) THEN'));
    expect(sql, contains('actual_quantity_base'));
    expect(sql, contains('variance_quantity_base'));
    expect(sql, contains('variance_amount'));
    expect(
      sql,
      contains(
        "CASE WHEN COALESCE(p_complete, FALSE) THEN 'completed' ELSE 'in_progress' END",
      ),
    );
    expect(sql, contains('public.can_access_inventory_purchase_store'));
    expect(
      sql,
      contains(
        'GRANT EXECUTE ON FUNCTION public.save_inventory_stock_audit(UUID, JSONB, TEXT, BOOLEAN, UUID)',
      ),
    );
  });

  test('inventory purchase stock audit completion reuses draft session', () {
    final sql = readRepoFile(
      'supabase/migrations/20260506005000_inventory_purchase_stock_audit_save.sql',
    );

    expect(sql, contains('p_session_id UUID DEFAULT NULL'));
    expect(sql, contains('IF p_session_id IS NOT NULL THEN'));
    expect(sql, contains('UPDATE public.inventory_stock_audit_sessions'));
    expect(sql, contains('DELETE FROM public.inventory_stock_audit_lines'));
    expect(
      sql,
      contains(
        'GRANT EXECUTE ON FUNCTION public.save_inventory_stock_audit(UUID, JSONB, TEXT, BOOLEAN, UUID)',
      ),
    );
  });

  test(
    'inventory purchase manual POS order stays separate from Office purchase',
    () {
      final sql = readRepoFile(
        'supabase/migrations/20260506006000_inventory_purchase_manual_order.sql',
      );

      expect(
        sql,
        contains(
          'CREATE OR REPLACE FUNCTION public.create_manual_inventory_purchase_order',
        ),
      );
      expect(sql, contains('INSERT INTO public.inventory_purchase_orders'));
      expect(
        sql,
        contains('INSERT INTO public.inventory_purchase_order_lines'),
      );
      expect(sql, contains("'manual'"));
      expect(sql, contains("'pos'"));
      expect(
        sql,
        contains(
          'ordered_quantity_unit * v_supplier_item.order_unit_quantity_base',
        ),
      );
      expect(
        sql,
        contains(
          'GREATEST(v_ordered_quantity_unit, v_supplier_item.min_order_quantity)',
        ),
      );
      expect(
        sql,
        contains('public.recalculate_inventory_purchase_order_totals'),
      );
      expect(sql, contains('public.can_access_inventory_purchase_store'));
      expect(sql, isNot(contains('office_purchases')));
      expect(sql, isNot(contains('accounting.purchase_requests')));
    },
  );

  test(
    'inventory purchase repeat POS order duplicates an existing inventory order',
    () {
      final sql = readRepoFile(
        'supabase/migrations/20260515100000_inventory_repeat_purchase_order.sql',
      );

      expect(
        sql,
        contains(
          'CREATE OR REPLACE FUNCTION public.create_repeat_inventory_purchase_order',
        ),
      );
      expect(sql, contains('p_source_purchase_order_id UUID'));
      expect(sql, contains('SELECT *'));
      expect(sql, contains('FROM public.inventory_purchase_orders'));
      expect(sql, contains('INSERT INTO public.inventory_purchase_orders'));
      expect(
        sql,
        contains('INSERT INTO public.inventory_purchase_order_lines'),
      );
      expect(sql, contains("'repeat'"));
      expect(sql, contains("'repeat_pos'"));
      expect(sql, contains("'pos'"));
      expect(sql, contains('public.can_access_inventory_purchase_store'));
      expect(
        sql,
        contains('public.recalculate_inventory_purchase_order_totals'),
      );
      expect(
        sql,
        contains(
          'GRANT EXECUTE ON FUNCTION public.create_repeat_inventory_purchase_order(UUID, DATE, TEXT)',
        ),
      );
      expect(sql, isNot(contains('office_purchases')));
      expect(sql, isNot(contains('accounting.purchase_requests')));
    },
  );

  test(
    'inventory recommendation adjustments stay POS-owned before order creation',
    () {
      final sql = readRepoFile(recommendationAdjustmentPath);

      expect(
        sql,
        contains('ALTER TABLE public.inventory_recommendation_lines'),
      );
      expect(sql, contains('adjusted_order_units'));
      expect(sql, contains('adjusted_quantity_base'));
      expect(sql, contains('adjustment_memo'));
      expect(
        sql,
        contains(
          'CREATE OR REPLACE FUNCTION public.update_inventory_recommendation_line_adjustment',
        ),
      );
      expect(sql, contains('public.can_access_inventory_purchase_store'));
      expect(
        sql,
        contains('COALESCE(adjusted_order_units, recommended_order_units) > 0'),
      );
      expect(
        sql,
        contains(
          'COALESCE(rl.adjusted_order_units, rl.recommended_order_units) AS effective_order_units',
        ),
      );
      expect(
        sql,
        contains(
          'adjusted.effective_order_units * isi.order_unit_quantity_base',
        ),
      );
      expect(
        sql,
        contains("'adjusted_order_units', adjusted.adjusted_order_units"),
      );
      expect(
        sql,
        contains(
          'GRANT EXECUTE ON FUNCTION public.update_inventory_recommendation_line_adjustment(UUID, NUMERIC, TEXT)',
        ),
      );
      expect(sql, isNot(contains('office_purchases')));
      expect(sql, isNot(contains('accounting.purchase_requests')));
      expect(sql, isNot(contains('office_approve_inventory_purchase_order')));
    },
  );

  test(
    'inventory purchase supplier management RPCs validate POS-native access',
    () {
      final sql = readRepoFile(
        'supabase/migrations/20260506007000_inventory_supplier_management.sql',
      );

      expect(
        sql,
        contains('CREATE OR REPLACE FUNCTION public.upsert_inventory_supplier'),
      );
      expect(
        sql,
        contains(
          'CREATE OR REPLACE FUNCTION public.set_inventory_supplier_status',
        ),
      );
      expect(
        sql,
        contains(
          'CREATE OR REPLACE FUNCTION public.upsert_inventory_supplier_item',
        ),
      );
      expect(
        sql,
        contains(
          'CREATE OR REPLACE FUNCTION public.set_inventory_supplier_item_active',
        ),
      );
      expect(sql, contains('public.can_access_inventory_purchase_store'));
      expect(sql, contains('p_store_id UUID'));
      expect(sql, contains('order_unit_quantity_base'));
      expect(sql, contains('min_order_quantity'));
      expect(sql, contains('unit_price'));
      expect(sql, contains('public.inventory_suppliers'));
      expect(sql, contains('public.inventory_supplier_items'));
      expect(sql, isNot(contains('office_purchases')));
      expect(sql, isNot(contains('accounting.purchase_requests')));
    },
  );

  test(
    'inventory purchase product management RPCs keep inventory item linkage',
    () {
      final sql = readRepoFile(
        'supabase/migrations/20260506008000_inventory_product_management.sql',
      );

      expect(
        sql,
        contains('CREATE OR REPLACE FUNCTION public.upsert_inventory_product'),
      );
      expect(
        sql,
        contains(
          'CREATE OR REPLACE FUNCTION public.set_inventory_product_active',
        ),
      );
      expect(sql, contains('public.can_access_inventory_purchase_store'));
      expect(sql, contains('p_store_id UUID'));
      expect(sql, contains('base_unit_factor'));
      expect(sql, contains("CHECK"));
      expect(sql, contains('INSERT INTO public.inventory_items'));
      expect(sql, contains('inventory_item_id'));
      expect(sql, contains('UPDATE public.inventory_items'));
      expect(sql, contains('public.inventory_products'));
      expect(sql, isNot(contains('office_purchases')));
      expect(sql, isNot(contains('accounting.purchase_requests')));
    },
  );

  test(
    'inventory purchase recipe management deletes store-scoped recipe lines',
    () {
      final sql = readRepoFile(
        'supabase/migrations/20260506009000_inventory_recipe_management.sql',
      );

      expect(
        sql,
        contains(
          'CREATE OR REPLACE FUNCTION public.delete_inventory_recipe_line',
        ),
      );
      expect(sql, contains('public.can_access_inventory_purchase_store'));
      expect(sql, contains('p_store_id UUID'));
      expect(sql, contains('p_recipe_id UUID'));
      expect(sql, contains('DELETE FROM public.menu_recipes'));
      expect(sql, contains('restaurant_id = p_store_id'));
      expect(
        sql,
        contains(
          'GRANT EXECUTE ON FUNCTION public.delete_inventory_recipe_line',
        ),
      );
      expect(sql, isNot(contains('office_purchases')));
      expect(sql, isNot(contains('accounting.purchase_requests')));
    },
  );

  test('inventory purchase consumption refresh aggregates POS recipe sales', () {
    final sql = readRepoFile(
      'supabase/migrations/20260506010000_inventory_consumption_refresh.sql',
    );

    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.refresh_inventory_daily_consumption',
      ),
    );
    expect(sql, contains('public.can_access_inventory_purchase_store'));
    expect(sql, contains('public.order_items'));
    expect(sql, contains('public.menu_recipes'));
    expect(sql, contains('public.inventory_products'));
    expect(sql, contains('INSERT INTO public.inventory_daily_consumption'));
    expect(
      sql,
      contains(
        'ON CONFLICT (restaurant_id, product_id, consumption_date, source)',
      ),
    );
    expect(sql, contains("source = 'pos'"));
    expect(sql, isNot(contains('office_purchases')));
    expect(sql, isNot(contains('accounting.purchase_requests')));
  });

  test('inventory purchase cost analysis summarizes consumption costs', () {
    final sql = readRepoFile(
      'supabase/migrations/20260506011000_inventory_cost_analysis.sql',
    );

    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.get_inventory_cost_analysis'),
    );
    expect(sql, contains('public.can_access_inventory_purchase_store'));
    expect(sql, contains('inventory_daily_consumption'));
    expect(sql, contains('inventory_supplier_items'));
    expect(sql, contains('consumed_amount'));
    expect(sql, contains('avg_unit_cost'));
    expect(sql, contains('preferred_unit_cost'));
    expect(sql, contains('cost_status'));
    expect(sql, isNot(contains('office_purchases')));
    expect(sql, isNot(contains('accounting.purchase_requests')));
  });

  test(
    'inventory purchase new menu registration creates menu and recipes atomically',
    () {
      final sql = readRepoFile(
        'supabase/migrations/20260506012000_inventory_new_menu_registration.sql',
      );

      expect(
        sql,
        contains(
          'CREATE OR REPLACE FUNCTION public.create_inventory_menu_with_recipe',
        ),
      );
      expect(sql, contains('public.can_access_inventory_purchase_store'));
      expect(sql, contains('INSERT INTO public.menu_items'));
      expect(sql, contains('INSERT INTO public.menu_recipes'));
      expect(sql, contains('p_recipe_lines JSONB'));
      expect(sql, contains('quantity_g'));
      expect(sql, contains('public.inventory_products'));
      expect(sql, isNot(contains('office_purchases')));
      expect(sql, isNot(contains('accounting.purchase_requests')));
    },
  );
}
