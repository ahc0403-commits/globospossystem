import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('qr table ordering migration exposes only token-backed anon RPCs', () {
    final migration = readRepoFile(
      'supabase/migrations/20260710000000_qr_table_ordering_v1.sql',
    );

    expect(
      migration,
      contains('CREATE TABLE IF NOT EXISTS public.table_qr_tokens'),
    );
    expect(
      migration,
      contains('CREATE TABLE IF NOT EXISTS public.qr_order_batches'),
    );
    expect(migration, contains("order_source IN ('staff', 'qr')"));
    expect(migration, contains('client_order_id uuid NOT NULL UNIQUE'));
    expect(migration, contains('result_snapshot jsonb NOT NULL'));
    expect(migration, contains('extensions.gen_random_bytes(24)'));
    expect(migration, contains('public.require_admin_actor_for_restaurant'));
    expect(
      migration,
      contains(
        "u.role IN ('admin', 'store_admin', 'brand_admin', 'super_admin')",
      ),
    );
    expect(
      migration,
      contains('CREATE OR REPLACE FUNCTION public.qr_get_menu'),
    );
    expect(
      migration,
      contains('CREATE OR REPLACE FUNCTION public.qr_place_order'),
    );
    expect(
      migration,
      contains(
        'CREATE OR REPLACE FUNCTION public.search_active_order_for_cashier',
      ),
    );
    expect(
      migration,
      contains('CREATE OR REPLACE FUNCTION public.admin_generate_table_qr'),
    );
    expect(
      migration,
      contains(
        'REVOKE ALL ON public.table_qr_tokens FROM PUBLIC, anon, authenticated',
      ),
    );
    expect(
      migration,
      contains(
        'REVOKE ALL ON public.qr_order_batches FROM PUBLIC, anon, authenticated',
      ),
    );
    expect(
      migration,
      contains('GRANT EXECUTE ON FUNCTION public.qr_get_menu(text)'),
    );
    expect(
      migration,
      contains(
        'GRANT EXECUTE ON FUNCTION public.qr_place_order(text, jsonb, uuid)',
      ),
    );
    expect(migration, isNot(contains('GRANT INSERT ON public.orders TO anon')));
    expect(
      migration,
      isNot(contains('GRANT INSERT ON public.order_items TO anon')),
    );
  });

  test('qr place order keeps lifecycle payment and price contracts shared', () {
    final migration = readRepoFile(
      'supabase/migrations/20260710000000_qr_table_ordering_v1.sql',
    );

    expect(migration, contains('AND r.is_active = true'));
    expect(migration, contains('AND m.is_available = true'));
    expect(migration, contains('AND m.is_visible_public = true'));
    expect(migration, contains('m.price'));
    expect(migration, contains('QR_TOO_FREQUENT'));
    expect(migration, contains('v_item_count < 1 OR v_item_count > 20'));
    expect(migration, contains("(v_line.raw->>'quantity')::int > 20"));
    expect(migration, contains('QR_ORDER_PAYMENT_IN_PROGRESS'));
    final placeOrderStart = migration.indexOf(
      'CREATE OR REPLACE FUNCTION public.qr_place_order',
    );
    final tokenResolveIndex = migration.indexOf(
      'FROM public.table_qr_tokens q',
      placeOrderStart,
    );
    final tokenInvalidIndex = migration.indexOf(
      "RAISE EXCEPTION 'QR_TOKEN_INVALID'",
      tokenResolveIndex,
    );
    final idempotencyIndex = migration.indexOf(
      'FROM public.qr_order_batches',
      tokenInvalidIndex,
    );
    expect(placeOrderStart, greaterThanOrEqualTo(0));
    expect(tokenResolveIndex, greaterThan(placeOrderStart));
    expect(tokenInvalidIndex, greaterThan(tokenResolveIndex));
    expect(idempotencyIndex, greaterThan(tokenInvalidIndex));
    expect(migration, contains('AND restaurant_id = v_table.restaurant_id'));
    expect(migration, contains('AND table_id = v_table.table_id'));
    expect(
      migration,
      contains('public.void_active_order_discount_for_item_change'),
    );
    expect(migration, contains('public.recalc_order_status(v_order_id)'));
    expect(migration, contains('public.enqueue_print_jobs('));
    expect(migration, contains("ARRAY['kitchen', 'floor', 'confirmation']"));
    expect(migration, contains('RETURN v_existing_batch.result_snapshot'));
    expect(migration, contains("'qr_place_order'"));
    expect(migration, isNot(contains('process_payment(')));
  });

  test('confirmation slips reuse print routing and render cashier-only copy', () {
    final migration = readRepoFile(
      'supabase/migrations/20260710000000_qr_table_ordering_v1.sql',
    );
    final receiptBuilder = readRepoFile(
      'lib/core/hardware/receipt_builder.dart',
    );
    final printAgent = readRepoFile(
      'lib/core/hardware/print_job_agent_service.dart',
    );

    expect(
      migration,
      contains("copy_type IN ('kitchen', 'floor', 'tray', 'confirmation')"),
    );
    expect(migration, contains("IF v_copy_type IN ('floor', 'confirmation')"));
    expect(
      migration,
      contains(
        "IF v_destination_id IS NULL AND v_copy_type IN ('floor', 'tray', 'confirmation')",
      ),
    );
    expect(receiptBuilder, contains('buildConfirmationSlip'));
    expect(receiptBuilder, contains('ORDER CONFIRMATION'));
    expect(receiptBuilder, contains('Please bring this slip to cashier.'));
    expect(
      receiptBuilder,
      contains('This is not a receipt. Payment at cashier only.'),
    );
    expect(
      printAgent,
      contains(
        "'confirmation' => ReceiptBuilder.buildConfirmationSlip(job.ticket)",
      ),
    );
    expect(migration, contains("'print_enqueue_failed'"));
    expect(migration, contains("'created_at_utc', now()"));
  });

  test('staff surfaces expose qr source and admin qr controls', () {
    final kitchenProvider = readRepoFile(
      'lib/features/kitchen/kitchen_provider.dart',
    );
    final kitchenScreen = readRepoFile(
      'lib/features/kitchen/kitchen_screen.dart',
    );
    final paymentProvider = readRepoFile(
      'lib/features/payment/payment_provider.dart',
    );
    final cashierScreen = readRepoFile(
      'lib/features/cashier/cashier_screen.dart',
    );
    final menuService = readRepoFile('lib/core/services/menu_service.dart');
    final menuProvider = readRepoFile(
      'lib/features/admin/providers/menu_provider.dart',
    );
    final menuTab = readRepoFile('lib/features/admin/tabs/menu_tab.dart');
    final tablesService = readRepoFile('lib/core/services/tables_service.dart');
    final tablesProvider = readRepoFile(
      'lib/features/admin/providers/tables_provider.dart',
    );
    final tablesTab = readRepoFile('lib/features/admin/tabs/tables_tab.dart');
    final pubspec = readRepoFile('pubspec.yaml');

    expect(kitchenProvider, contains('order_source'));
    expect(
      kitchenProvider,
      contains('bool get isQrOrder => orderSource == \'qr\''),
    );
    expect(kitchenScreen, contains("Key('kitchen_qr_order_badge_"));
    expect(paymentProvider, contains('order_source'));
    expect(
      paymentProvider,
      contains('bool get isQrOrder => orderSource == \'qr\''),
    );
    expect(paymentProvider, contains('class CashierOrderSearchResult'));
    expect(paymentProvider, contains('searchActiveOrderForCashier'));
    expect(
      paymentProvider,
      contains(".inFilter('status', ['pending', 'confirmed', 'serving'])"),
    );
    expect(paymentProvider, contains('search_active_order_for_cashier'));
    expect(paymentProvider, contains('tables(table_number)'));
    expect(cashierScreen, contains('cashier_qr_order_badge_'));
    expect(cashierScreen, contains("Key('cashier_order_search')"));
    expect(cashierScreen, contains("Key('cashier_order_search_action')"));
    expect(cashierScreen, contains("Key('cashier_order_search_status')"));
    expect(cashierScreen, contains('Kitchen in progress'));
    expect(cashierScreen, contains('_filterCashierOrders'));
    expect(cashierScreen, contains('_handleOrderSearch'));
    expect(menuService, contains('togglePublicVisibility'));
    expect(menuProvider, contains('togglePublicVisibility'));
    expect(menuTab, contains('admin_menu_qr_public_'));
    expect(tablesService, contains('admin_generate_table_qr'));
    expect(tablesProvider, contains('generateTableQr'));
    expect(pubspec, contains('qr_flutter:'));
    expect(tablesTab, contains('QrImageView'));
    expect(tablesTab, contains("Key('admin_tables_generate_qr_action')"));
    expect(tablesTab, contains("Key('admin_table_qr_rotate_warning_dialog')"));
    expect(tablesTab, contains("Key('admin_table_qr_rotate_warning')"));
    expect(tablesTab, contains("Key('admin_table_qr_preview')"));
    expect(tablesTab, contains("Key('admin_table_qr_url')"));
    expect(tablesTab, contains(r"'$origin/#/qr/$token'"));
    expect(tablesTab, isNot(contains(r"'$origin/qr/$token'")));
  });
}
