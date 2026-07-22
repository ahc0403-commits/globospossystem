import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('pilot feedback opens store and brand admin operational access', () {
    final migration = readRepoFile(
      'supabase/migrations/20260616000000_pos_pilot_feedback_closure.sql',
    );
    final adminHelper = readRepoFile(
      'supabase/migrations/20260428000001_harden_admin_actor_helper_multi_access.sql',
    );

    expect(
      adminHelper,
      contains(
        "v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin')",
      ),
    );
    expect(migration, contains('public.require_pos_admin_actor_for_store'));
    expect(
      migration,
      contains(
        "v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin')",
      ),
    );
    expect(migration, contains('public.create_daily_closing'));
    expect(migration, contains('public.get_daily_closings'));
    expect(migration, contains('public.get_admin_today_summary'));
    expect(migration, contains('public.user_accessible_stores(auth.uid())'));
  });

  test('waiter can see sent order details and edit active guest count', () {
    final model = readRepoFile('lib/features/order/order_model.dart');
    final provider = readRepoFile('lib/features/order/order_provider.dart');
    final service = readRepoFile('lib/core/services/order_service.dart');
    final waiter = readRepoFile('lib/features/waiter/waiter_screen.dart');
    final workspace = readRepoFile('lib/widgets/order_workspace.dart');
    final migration = readRepoFile(
      'supabase/migrations/20260616000000_pos_pilot_feedback_closure.sql',
    );

    expect(model, contains('final int? guestCount;'));
    expect(provider, contains('guest_count'));
    expect(provider, contains('Future<void> updateGuestCount('));
    expect(service, contains('update_order_guest_count'));
    expect(
      migration,
      contains('CREATE OR REPLACE FUNCTION public.update_order_guest_count'),
    );
    expect(waiter, contains('orderState.activeOrder?.guestCount'));
    expect(waiter, contains('onChangeGuestCount'));
    expect(workspace, contains("Key('order_guest_count_edit_action')"));
    expect(workspace, contains('order_sent_items_always_visible_detail'));
    expect(workspace, contains('initiallyExpanded: true'));
  });

  test('kitchen completes tickets without a separate handoff lane', () {
    final provider = readRepoFile('lib/features/kitchen/kitchen_provider.dart');
    final screen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');

    expect(provider, contains('completedOrders'));
    expect(
      provider,
      contains(
        ".inFilter('status', ['pending', 'confirmed', 'serving', 'completed'])",
      ),
    );
    expect(provider, contains("item.status == 'served'"));
    expect(provider, contains("item.status != 'served'"));
    expect(screen, contains("Key('kitchen_completed_history_panel')"));
    expect(screen, contains('l10n.kitchenStartCooking'));
    expect(screen, contains('l10n.kitchenMarkComplete'));
    expect(screen, contains('l10n.kitchenCompleteAllItems'));
    expect(screen, isNot(contains('l10n.kitchenHandoffComplete')));
    expect(screen, contains('_orderPriorityColor'));
    expect(screen, contains('_elapsedLabel'));
  });

  test('cashier keeps payable queue and completed order lookup separate', () {
    final provider = readRepoFile('lib/features/payment/payment_provider.dart');
    final screen = readRepoFile('lib/features/cashier/cashier_screen.dart');

    expect(provider, contains('completedOrders'));
    expect(
      provider,
      contains('Future<List<CashierOrder>> _fetchCompletedOrders'),
    );
    expect(provider, contains(".eq('status', 'completed')"));
    expect(provider, contains(".gte('updated_at', todayStart)"));
    expect(screen, contains('class _CashierCompletedOrderHistory'));
    expect(screen, contains("Key('cashier_completed_order_history')"));
    expect(screen, contains("Key('cashier_payment_method_required_hint')"));
    expect(screen, contains('l10n.cashierCompletedStatus'));
    expect(screen, contains('l10n.changeHistory'));
  });

  test('admin report exposes order accuracy metrics for pilot review', () {
    final reports = readRepoFile('lib/features/admin/tabs/reports_tab.dart');
    final migration = readRepoFile(
      'supabase/migrations/20260616000000_pos_pilot_feedback_closure.sql',
    );

    expect(reports, contains("Key('reports_order_accuracy_metrics')"));
    expect(reports, contains('l10n.reportsTotalOrders'));
    expect(reports, contains('l10n.reportsAverageOrderAmount'));
    expect(migration, contains("'payments_count', v_payments_count"));
    expect(
      migration,
      contains(
        "'orders_total', v_orders_pending + v_orders_confirmed + v_orders_serving + v_orders_completed + v_orders_cancelled",
      ),
    );
  });
}
