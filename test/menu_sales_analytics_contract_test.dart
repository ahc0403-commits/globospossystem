import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'menu analytics RPC preserves identity and deduplicates split payments',
    () {
      final migration = readRepoFile(
        'supabase/migrations/20260813120000_menu_sales_analytics.sql',
      );

      expect(migration, contains('menu_item_id_snapshot uuid'));
      expect(migration, contains('ORDER_ITEM_MENU_IDENTITY_IMMUTABLE'));
      expect(migration, contains('max(payment.created_at) AS paid_at'));
      expect(migration, contains("order_row.status = 'completed'"));
      expect(migration, contains('payment.is_revenue = true'));
      expect(migration, contains("item.item_type = 'menu_item'"));
      expect(migration, contains("item.status <> 'cancelled'"));
      expect(
        migration,
        contains('COALESCE(item.is_service_item, false) = false'),
      );
      expect(migration, contains("AT TIME ZONE 'Asia/Ho_Chi_Minh'"));
      expect(migration, contains("'external_sales'"));
      expect(migration, contains("'photo_objet_sales'"));
      expect(migration, contains("'adjustment_allocation', 'unallocated'"));
    },
  );

  test('menu analytics RPC is read-only and store-scoped', () {
    final migration = readRepoFile(
      'supabase/migrations/20260813120000_menu_sales_analytics.sql',
    );

    expect(migration, contains('STABLE'));
    expect(migration, contains('SECURITY DEFINER'));
    expect(
      migration,
      contains('PERFORM public.require_admin_actor_for_restaurant(p_store_id)'),
    );
    expect(migration, contains('FROM PUBLIC, anon'));
    expect(migration, contains('TO authenticated, service_role'));
    expect(
      migration,
      isNot(contains('CREATE OR REPLACE FUNCTION public.process_payment')),
    );
  });

  test('menu analytics production gates protect core POS contracts', () {
    final preflight = readRepoFile(
      'scripts/preflight_menu_sales_analytics.sql',
    );
    final verification = readRepoFile(
      'scripts/verify_menu_sales_analytics.sql',
    );
    final rollback = readRepoFile('scripts/rollback_menu_sales_analytics.sql');

    for (final sql in [preflight, verification, rollback]) {
      expect(sql, contains('process_payment(uuid,uuid,numeric,text)'));
      expect(sql, contains('create_order(uuid,uuid,jsonb)'));
      expect(sql, contains("('restaurants', 'name')"));
      expect(sql, contains("('restaurants', 'address')"));
      expect(sql, contains("('restaurants', 'is_active')"));
    }
    expect(
      preflight,
      contains('MENU_SALES_ANALYTICS_UNTRACKED_OBJECT_PRESENT'),
    );
    expect(
      verification,
      contains('MENU_SALES_ANALYTICS_VERIFY_SNAPSHOT_BACKFILL_FAILED'),
    );
    expect(
      verification,
      contains('MENU_SALES_ANALYTICS_VERIFY_RPC_PRIVILEGE_INVALID'),
    );
    expect(
      rollback,
      contains('MENU_SALES_ANALYTICS_ROLLBACK_CORE_POS_DAMAGED'),
    );
  });

  test('reports export and UI include menu sales slices', () {
    final provider = readRepoFile('lib/features/report/report_provider.dart');
    final reports = readRepoFile('lib/features/admin/tabs/reports_tab.dart');
    final screens = readRepoFile(
      'lib/features/admin/report_analysis_screens.dart',
    );
    final panel = readRepoFile(
      'lib/features/report/menu_sales_analytics_panel.dart',
    );

    expect(provider, contains("excel['Menu Sales']"));
    expect(provider, contains("excel['Menu by Hour']"));
    expect(reports, contains('MenuSalesAnalyticsScreen('));
    expect(reports, isNot(contains('MenuSalesAnalyticsPanel(')));
    expect(screens, contains('MenuSalesAnalyticsPanel('));
    expect(reports, isNot(contains('summary == null || !menuSalesReady')));
    expect(panel, contains("Key('menu_sales_ranking')"));
    expect(panel, contains("Key('menu_sales_hourly')"));
    expect(panel, contains("Key('menu_sales_scope_banner')"));
  });

  test('combo menu analytics uses immutable snapshots and explicit scope', () {
    final migration = readRepoFile(
      'supabase/migrations/20260813132500_menu_sales_combo_filter.sql',
    );
    final preflight = readRepoFile(
      'scripts/preflight_menu_sales_combo_filter.sql',
    );
    final verification = readRepoFile(
      'scripts/verify_menu_sales_combo_filter.sql',
    );
    final rollback = readRepoFile(
      'scripts/rollback_menu_sales_combo_filter.sql',
    );
    final model = readRepoFile('lib/features/report/menu_sales_analytics.dart');
    final panel = readRepoFile(
      'lib/features/report/menu_sales_analytics_panel.dart',
    );

    expect(migration, contains('p_include_combos boolean'));
    expect(migration, contains('item.combo_components'));
    expect(migration, contains('jsonb_array_length'));
    expect(migration, contains("'is_combo', menu.is_combo"));
    expect(migration, contains("'combo_identity_basis'"));
    expect(model, contains("'p_include_combos': params.includeCombos"));
    expect(panel, contains("Key('menu_sales_include_combos')"));
    expect(panel, contains("Key('menu_sales_exclude_combos')"));
    expect(panel, contains("Key('menu_sales_combo_badge_\${row.menuKey}')"));
    expect(preflight, contains('MENU_SALES_COMBO_FILTER_PREFLIGHT_OK'));
    expect(verification, contains('MENU_SALES_COMBO_FILTER_VERIFY_OK'));
    expect(rollback, contains('MENU_SALES_COMBO_FILTER_ROLLBACK_OK'));
  });
}
