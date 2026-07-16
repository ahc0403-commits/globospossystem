import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migration =
      'supabase/migrations/20260716190000_restaurant_daily_cutoff.sql';
  const preflight = 'scripts/preflight_restaurant_daily_cutoff.sql';
  const verification = 'scripts/verify_restaurant_daily_cutoff.sql';
  const rollback = 'scripts/rollback_restaurant_daily_cutoff.sql';
  const deploy = 'scripts/deploy_pos_production.sh';
  const service = 'lib/core/services/restaurant_cutoff_service.dart';
  const waiter = 'lib/features/waiter/waiter_screen.dart';
  const cashier = 'lib/features/cashier/cashier_screen.dart';
  const workspace = 'lib/widgets/order_workspace.dart';
  const orderProvider = 'lib/features/order/order_provider.dart';
  const paymentProvider = 'lib/features/payment/payment_provider.dart';

  test('Restaurant policy is explicit, server-owned, and Photo-safe', () {
    final sql = readRepoFile(migration);

    expect(sql, contains('public.restaurant_cutoff_policies'));
    expect(sql, contains('restaurant_id uuid PRIMARY KEY'));
    expect(sql, contains('is_enabled boolean NOT NULL DEFAULT true'));
    expect(sql, contains('Asia/Ho_Chi_Minh'));
    expect(sql, contains('statement_timestamp()'));
    expect(sql, isNot(contains('DateTime.now')));
    expect(sql, isNot(contains('brand_name')));
    expect(sql, isNot(contains('store_name ILIKE')));
    expect(sql, isNot(contains('photo_objet_sales')));
    expect(sql, isNot(contains('UPDATE public.photo_objet')));
    expect(sql, isNot(contains('DELETE FROM public.photo_objet')));
  });

  test('authoritative boundaries and stable errors are enforced in DB', () {
    final sql = readRepoFile(migration);

    expect(sql, contains("TIME '21:30:00'"));
    expect(sql, contains("TIME '21:45:00'"));
    expect(sql, contains('RESTAURANT_KITCHEN_CLOSED'));
    expect(sql, contains('RESTAURANT_DAILY_SALES_CLOSED'));
    expect(sql, contains('restaurant_assert_kitchen_mutation_allowed_at'));
    expect(sql, contains('restaurant_assert_payment_allowed_at'));
    expect(sql, contains('trg_restaurant_cutoff_orders'));
    expect(sql, contains('trg_restaurant_cutoff_order_items'));
    expect(sql, contains('trg_restaurant_cutoff_payments'));
    expect(sql, contains('trg_restaurant_cutoff_external_sales'));
    expect(sql, contains('BEFORE INSERT OR UPDATE'));
    expect(sql, contains('SECURITY INVOKER'));
    expect(
      sql,
      contains(
        'GRANT EXECUTE ON FUNCTION public.restaurant_cutoff_state_at',
      ),
    );
  });

  test('single 22:20 finalization fails closed without a fallback', () {
    final sql = readRepoFile(migration);

    expect(sql, contains('restaurant_daily_sales_finalizations'));
    expect(sql, contains('trg_restaurant_finalization_immutable'));
    expect(sql, contains('data_integrity_failed'));
    expect(sql, contains('post_cutoff_receipt_count'));
    expect(sql, contains('offending_stores'));
    expect(sql, contains("TIME '22:20:00'"));
    expect(sql, contains("'20 15 * * *'"));
    expect(sql, contains('restaurant-daily-sales-finalize-2220-hcm'));
    expect(sql, contains('UNIQUE (business_date)'));
    expect(sql, isNot(contains('23:00')));
    expect(sql, isNot(contains('22:30')));
    expect(sql, isNot(contains('retry')));
  });

  test('receipt timestamps and hourly reporting remain available', () {
    final sql = readRepoFile(migration);

    expect(sql, contains('public.v_restaurant_sales_receipts'));
    expect(sql, contains('receipt_id'));
    expect(sql, contains('sold_at'));
    expect(sql, contains('sale_hour_hcm'));
    expect(sql, contains("'hour'"));
    expect(sql, contains('WITH (security_invoker = true)'));
  });

  test('offline replay reaches the same server-enforced mutation boundary', () {
    final orders = readRepoFile(orderProvider);

    expect(orders, contains('syncOfflineQueue'));
    expect(orders, contains('orderService.createOrder'));
    expect(orders, contains('orderService.addItemsToOrder'));
    expect(orders, contains('OfflineMutationQueueService.createOrderType'));
    expect(orders, contains('OfflineMutationQueueService.addItemsToOrderType'));
    expect(orders, contains('RESTAURANT_KITCHEN_CLOSED'));
    expect(orders, contains('RESTAURANT_DAILY_SALES_CLOSED'));
  });

  test('UI consumes server state and localizes stable errors', () {
    final source = readRepoFile(service);
    final waiterSource = readRepoFile(waiter);
    final cashierSource = readRepoFile(cashier);
    final workspaceSource = readRepoFile(workspace);
    final orderErrors = readRepoFile(orderProvider);
    final paymentErrors = readRepoFile(paymentProvider);

    expect(source, contains("'get_restaurant_cutoff_state'"));
    expect(source, contains('restaurantCutoffStateProvider'));
    expect(waiterSource, contains('restaurantCutoffStateProvider'));
    expect(cashierSource, contains('restaurantCutoffStateProvider'));
    expect(workspaceSource, contains('canCreateSales'));
    expect(workspaceSource, contains('canCompletePayment'));
    expect(orderErrors, contains('RESTAURANT_KITCHEN_CLOSED'));
    expect(paymentErrors, contains('RESTAURANT_DAILY_SALES_CLOSED'));

    for (final arb in [
      'lib/l10n/app_en.arb',
      'lib/l10n/app_ko.arb',
      'lib/l10n/app_vi.arb',
    ]) {
      final localized = readRepoFile(arb);
      expect(localized, contains('restaurantKitchenClosed'));
      expect(localized, contains('restaurantDailySalesClosed'));
    }
  });

  test('production migration has explicit gates and reversible behavior', () {
    final deployment = readRepoFile(deploy);

    for (final path in [preflight, verification, rollback]) {
      expect(File(path).existsSync(), isTrue, reason: '$path must exist');
    }
    expect(deployment, contains('20260716190000_restaurant_daily_cutoff.sql'));
    expect(deployment, contains('preflight_restaurant_daily_cutoff.sql'));
    expect(deployment, contains('verify_restaurant_daily_cutoff.sql'));
  });
}
