import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('kitchen skips handoff and supports atomic whole-ticket completion', () {
    final screen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');
    final provider = readRepoFile('lib/features/kitchen/kitchen_provider.dart');
    final service = readRepoFile('lib/core/services/order_service.dart');
    final migration = readRepoFile(
      'supabase/migrations/20260722020000_kitchen_direct_completion.sql',
    );

    expect(screen, contains("'preparing' => 'served'"));
    expect(screen, contains('kitchenCompleteAllItems'));
    expect(screen, contains('ToastResponsiveScrollBody('));
    expect(screen, isNot(contains('l10n.kitchenReadyHandoff')));
    expect(screen, isNot(contains('l10n.kitchenHandoffComplete')));
    expect(provider, contains('Future<void> completeOrder(String orderId)'));
    expect(service, contains("'complete_kitchen_order'"));
    expect(
      migration,
      contains("v_item.status = 'preparing' AND p_new_status = 'served'"),
    );
    expect(
      migration,
      contains('CREATE OR REPLACE FUNCTION public.complete_kitchen_order'),
    );
    expect(migration, contains("SET status = 'served'"));
    expect(migration, contains("status IN ('pending', 'preparing', 'ready')"));
    expect(
      migration,
      contains('PERFORM public.recalc_order_status(p_order_id)'),
    );
  });

  test('customer QR completion queues confirmation to its floor printer', () {
    final qrMigration = readRepoFile(
      'supabase/migrations/20260710000000_qr_table_ordering_v1.sql',
    );
    final kitchen = readRepoFile('lib/features/kitchen/kitchen_screen.dart');
    final printStation = readRepoFile(
      'lib/features/print_station/print_station_screen.dart',
    );
    final router = readRepoFile('lib/core/router/app_router.dart');

    expect(qrMigration, contains("ARRAY['kitchen', 'floor', 'confirmation']"));
    expect(
      qrMigration,
      contains("IF v_copy_type IN ('floor', 'confirmation')"),
    );
    expect(qrMigration, contains("AND floor_label = v_order.floor_label"));
    expect(kitchen, contains('_printJobAgent.startPolling(storeId)'));
    expect(printStation, contains('_ensureAutoStarted(storeId)'));
    expect(printStation, contains('_agent.startPolling(storeId)'));
    expect(router, contains('PrintStationScreen(autoStart: true)'));
    expect(router, contains('KitchenScreen(autoStartPrinting: true)'));
  });
}
