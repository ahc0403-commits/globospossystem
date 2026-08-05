import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260805090000_pos_live_events_all_domains.sql';

  test('all operational domains publish a store-scoped invalidation event', () {
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains('CREATE TABLE IF NOT EXISTS public.pos_live_events'));
    expect(
      sql,
      contains(
        'ALTER PUBLICATION supabase_realtime ADD TABLE public.pos_live_events',
      ),
    );
    expect(sql, contains("('orders', 'orders')"));
    expect(sql, contains("('payments', 'payments')"));
    expect(sql, contains("('menu_items', 'menu')"));
    expect(sql, contains("('users', 'staff')"));
    expect(sql, contains("('attendance_logs', 'attendance')"));
    expect(sql, contains("('inventory_purchase_orders', 'inventory')"));
    expect(sql, contains("('qc_checks', 'qc')"));
    expect(sql, contains("('delivery_settlements', 'delivery')"));
    expect(sql, contains("('meinvoice_jobs', 'einvoice')"));
    expect(sql, contains("('print_jobs', 'print')"));
    expect(sql, contains("('photo_objet_sales', 'photo_ops')"));
    expect(sql, contains("('restaurants', 'settings')"));
    expect(sql, contains("event_type IN ('INSERT', 'UPDATE', 'DELETE')"));
    expect(sql, contains('pos_live_events_public_menu_read'));
    expect(sql, contains('GRANT SELECT ON public.pos_live_events TO anon'));
  });

  test(
    'shared client feed is filtered, debounced, and has reconnect fallback',
    () {
      final source = File(
        'lib/core/services/live_refresh_service.dart',
      ).readAsStringSync();

      expect(source, contains("table: 'pos_live_events'"));
      expect(source, contains("column: 'restaurant_id'"));
      expect(source, contains('Duration(milliseconds: 350)'));
      expect(source, contains('Duration(seconds: 30)'));
      expect(source, contains('!realtimeConnected'));
    },
  );

  test('every used staff POS surface listens without adding waiter work', () {
    const surfaces = <String>[
      'lib/main.dart',
      'lib/features/admin/admin_screen.dart',
      'lib/features/cashier/cashier_screen.dart',
      'lib/features/kitchen/kitchen_screen.dart',
      'lib/features/payment/payment_detail_screen.dart',
      'lib/features/qc/qc_check_screen.dart',
      'lib/features/qc/qc_review_screen.dart',
      'lib/features/photo_ops/photo_ops_screen.dart',
      'lib/features/print_station/print_station_screen.dart',
      'lib/features/super_admin/super_admin_screen.dart',
    ];

    for (final path in surfaces) {
      expect(
        File(path).readAsStringSync(),
        contains('posLiveEventsProvider'),
        reason: '$path must participate in live refresh',
      );
    }
  });

  test('anonymous QR menu subscribes by store with a silent fallback', () {
    final source = File(
      'lib/features/qr_order/qr_order_screen.dart',
    ).readAsStringSync();

    expect(source, contains('Timer.periodic(const Duration(seconds: 15)'));
    expect(source, contains('AppLifecycleState.resumed'));
    expect(source, contains("table: 'pos_live_events'"));
    expect(source, contains("column: 'restaurant_id'"));
    expect(source, contains("event.affects({'menu', 'tables', 'settings'})"));
    expect(source, contains('_loadMenu(showLoading: false)'));
    expect(source, contains('_cart.removeWhere'));
  });
}
