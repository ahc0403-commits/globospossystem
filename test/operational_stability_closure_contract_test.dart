import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/offline_mutation_queue_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migrationPath =
      'supabase/migrations/20260513020000_operational_stability_closure.sql';

  test('offline order queue has backend idempotency anchors', () {
    final sql = readRepoFile(migrationPath);
    final orderService = readRepoFile('lib/core/services/order_service.dart');
    final orderProvider = readRepoFile(
      'lib/features/order/order_provider.dart',
    );
    final queueService = readRepoFile(
      'lib/core/services/offline_mutation_queue_service.dart',
    );
    final workspace = readRepoFile('lib/widgets/order_workspace.dart');

    expect(
      sql,
      contains(
        'CREATE TABLE IF NOT EXISTS public.pos_client_mutation_attempts',
      ),
    );
    expect(sql, contains('actor_id UUID NOT NULL REFERENCES auth.users(id)'));
    expect(sql, contains('CLIENT_MUTATION_ACTOR_REQUIRED'));
    expect(sql, contains('UNIQUE (store_id, actor_id, client_mutation_id)'));
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.create_order_with_client_mutation_id',
      ),
    );
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.add_items_to_order_with_client_mutation_id',
      ),
    );
    expect(orderService, contains('create_order_with_client_mutation_id'));
    expect(
      orderService,
      contains('add_items_to_order_with_client_mutation_id'),
    );
    expect(orderProvider, contains('offlineMutationQueueService.enqueue'));
    expect(orderProvider, contains('syncOfflineQueue'));
    expect(orderProvider, contains('clientMutationId: entry.id'));
    expect(queueService, contains('pos_offline_mutation_queue_v1'));
    expect(workspace, contains('Offline orders are queued locally'));
  });

  test('kitchen consumption and stock audit reconciliation stays read-only', () {
    final sql = readRepoFile(migrationPath);

    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.get_inventory_kitchen_stock_reconciliation',
      ),
    );
    expect(sql, contains('inventory_daily_consumption'));
    expect(sql, contains("source = 'pos'"));
    expect(sql, contains('inventory_transactions'));
    expect(sql, contains("'inventory_stock_audit'"));
    expect(sql, contains("'inventory_purchase_receipt'"));
    expect(sql, contains('reconciliation_gap_base'));
    expect(sql, isNot(contains('UPDATE public.inventory_items')));
    expect(sql, isNot(contains('INSERT INTO public.inventory_transactions')));
  });

  test(
    'macOS printer recovery guards payload, timeout, and socket cleanup',
    () {
      final printer = readRepoFile(
        'lib/core/hardware/wifi_printer_service.dart',
      );

      expect(printer, contains('connectionTimeout'));
      expect(printer, contains('printFlushTimeout'));
      expect(printer, contains('socketCloseTimeout'));
      expect(printer, contains('if (bytes.isEmpty)'));
      expect(printer, contains('on TimeoutException'));
      expect(printer, contains('socket?.destroy();'));
    },
  );

  test('offline mutation queue persists and marks retry failure', () async {
    SharedPreferences.setMockInitialValues({});
    final preferences = await SharedPreferences.getInstance();
    final queue = OfflineMutationQueueService(preferences: preferences);
    final mutation = QueuedMutation(
      id: 'mutation-1',
      type: OfflineMutationQueueService.createOrderType,
      storeId: 'store-1',
      payload: const {
        'tableId': 'table-1',
        'items': [
          {'menu_item_id': 'menu-1', 'quantity': 2},
        ],
      },
      createdAt: DateTime.utc(2026, 5, 13),
    );

    await queue.enqueue(mutation);
    expect(await queue.pendingCount(), 1);

    await queue.markFailed('mutation-1', 'network timeout');
    final failed = (await queue.list()).single;
    expect(failed.attempts, 1);
    expect(failed.lastError, contains('network timeout'));

    await queue.remove('mutation-1');
    expect(await queue.pendingCount(), 0);
  });
}
