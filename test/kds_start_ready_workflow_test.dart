import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';

EmergencyFulfillmentItem _item({
  String id = 'item-1',
  int ordered = 2,
  int done = 0,
  int handed = 0,
  int served = 0,
  int excused = 0,
  int? readySequence,
  int? trayReadySequence,
  String route = 'kitchen_tray_floor',
  String nameKo = '메뉴',
}) => EmergencyFulfillmentItem(
  id: id,
  orderItemId: 'order-$id',
  nameKo: nameKo,
  nameVi: 'Món',
  nameEn: 'Item',
  orderedQuantity: ordered,
  kitchenStartedQuantity: done,
  kitchenDoneQuantity: done,
  trayReceivedQuantity: handed,
  trayDispatchedQuantity: handed,
  floorServedQuantity: served,
  excusedQuantity: excused,
  needsReview: false,
  workflowVersion: 2,
  fulfillmentRoute: route,
  oldestReadySequence: readySequence,
  oldestTrayReadySequence: trayReadySequence,
);

EmergencyFulfillmentOrder _order({
  required String id,
  required int queueNo,
  required DateTime createdAt,
  int? readySequence,
  int? trayReadySequence,
  EmergencyFulfillmentItem? item,
}) => EmergencyFulfillmentOrder(
  queueId: 'queue-$id',
  orderId: id,
  queueNo: queueNo,
  tableNumber: '$queueNo',
  floorLabel: queueNo.isEven ? '2F' : '1F',
  createdAt: createdAt,
  items: [item ?? _item(id: 'item-$id')],
  workflowVersion: 2,
  oldestReadySequence: readySequence,
  oldestTrayReadySequence: trayReadySequence,
);

void main() {
  test(
    'v2 preserves kitchen complete, floor handoff and served quantities',
    () {
      final waiting = _item();
      expect(waiting.isActionableAt('kitchen'), isTrue);
      expect(waiting.isActionableAt('tray'), isFalse);

      final completed = waiting.withStage('kitchen_done', 1);
      expect(completed.kitchenStartedQuantity, 1);
      expect(completed.kitchenDoneQuantity, 1);
      expect(completed.isActionableAt('tray'), isTrue);

      final handed = completed.withStage('tray_dispatched', 1);
      expect(handed.trayReceivedQuantity, 1);
      expect(handed.trayDispatchedQuantity, 1);
      expect(handed.readyUnservedQuantity, 1);

      final served = handed.withStage('floor_served', 1);
      expect(served.readyUnservedQuantity, 0);
      expect(served.isActionableAt('floor'), isFalse);
    },
  );

  test('kitchen card completes when the kitchen marks every item done', () {
    final receivedAt = DateTime.utc(2026, 9, 16, 10);
    final partialOrder = _order(
      id: 'A',
      queueNo: 1,
      createdAt: receivedAt,
      item: _item(done: 1),
    );
    expect(partialOrder.hasActionableQuantity('kitchen'), isTrue);
    expect(partialOrder.isRecentlyCompleteAt('kitchen'), isFalse);

    final completedOrder = partialOrder.copyWith(items: [_item(done: 2)]);
    expect(completedOrder.isRecentlyCompleteAt('kitchen'), isTrue);
    expect(completedOrder.isRecentlyCompleteAt('tray'), isFalse);
  });

  test('cashier-excused remainder closes work without erasing service', () {
    final item = _item(ordered: 3, done: 1, handed: 1, served: 1, excused: 2);
    expect(item.requiredQuantity, 1);
    expect(item.floorServedQuantity, 1);
    expect(item.isCompletedAt('floor'), isTrue);
    expect(item.isActionableAt('kitchen'), isFalse);
    expect(item.readyUnservedQuantity, 0);
  });

  test(
    'kitchen is arrival FIFO while tray and floor use their handoff sequences',
    () {
      final base = DateTime.utc(2026, 9, 16, 10);
      final a = _order(
        id: 'A',
        queueNo: 1,
        createdAt: base,
        trayReadySequence: 20,
        readySequence: 20,
      );
      final b = _order(
        id: 'B',
        queueNo: 2,
        createdAt: base.add(const Duration(minutes: 1)),
      );
      final c = _order(
        id: 'C',
        queueNo: 3,
        createdAt: base.add(const Duration(minutes: 2)),
        trayReadySequence: 10,
        readySequence: 10,
      );

      expect(
        sortEmergencyOrdersForStation([
          b,
          c,
          a,
        ], 'kitchen').map((order) => order.orderId),
        ['A', 'B', 'C'],
      );
      expect(
        sortEmergencyOrdersForStation([
          b,
          c,
          a,
        ], 'tray').map((order) => order.orderId),
        ['C', 'A', 'B'],
      );
      expect(
        sortEmergencyOrdersForStation([
          b,
          c,
          a,
        ], 'floor').map((order) => order.orderId),
        ['C', 'A', 'B'],
      );
    },
  );

  test(
    'v2 stage completion sorts to the bottom without reordering pending items',
    () {
      final first = _item(id: 'first', ordered: 1);
      final second = _item(id: 'second', ordered: 1);
      final third = _item(id: 'third', ordered: 1);
      for (final station in ['kitchen', 'tray', 'floor']) {
        final order = _order(
          id: 'A',
          queueNo: 1,
          createdAt: DateTime.utc(2026),
        ).copyWith(items: [first, second, third]);
        final completed = first
            .withStage('kitchen_done', 1)
            .withStage('tray_dispatched', 1)
            .withStage('floor_served', 1);
        final updated = order.copyWith(items: [completed, second, third]);
        expect(updated.displayItemsAt(station).map((item) => item.id), [
          'second',
          'third',
          'first',
        ]);
        expect(updated.visibleItemsAt(station).map((item) => item.id), [
          'second',
          'third',
          'first',
        ]);
      }
    },
  );

  test(
    'partially handed tray line remains pending until all cooked units leave',
    () {
      final partial = _item(done: 2, handed: 1);
      expect(partial.isDisplayCompletedAt('tray'), isFalse);
      expect(partial.isReadyFromPreviousStageAt('tray'), isTrue);
      expect(
        partial.withStage('tray_dispatched', 2).isDisplayCompletedAt('tray'),
        isTrue,
      );
      final drink = _item(route: 'floor_direct', served: 1);
      expect(drink.isReadyFromPreviousStageAt('floor'), isTrue);
      expect(
        drink.withStage('floor_served', 2).isReadyFromPreviousStageAt('floor'),
        isFalse,
      );
      expect(drink.isReadyFromPreviousStageAt('tray'), isFalse);
    },
  );

  test('migration keeps tray ready atomic and floor completion separate', () {
    final migration = File(
      'supabase/migrations/20260916190000_kds_start_ready_serve_workflow.sql',
    ).readAsStringSync();
    expect(migration, contains("p_action = 'tray_ready'"));
    expect(migration, contains('tray_received_quantity = v_received'));
    expect(migration, contains('tray_dispatched_quantity = v_dispatched'));
    expect(migration, contains('emergency_floor_ready_lots'));
    expect(migration, contains('KDS_WORKFLOW_VERSION_UNAVAILABLE'));
    expect(migration, contains('cashier_cancel_unserved_v1'));
    expect(migration, contains('excused_quantity'));
    expect(
      migration,
      contains('ITEM_HAS_SERVED_QUANTITY_USE_UNSERVED_CANCELLATION'),
    );
    for (final path in [
      'scripts/preflight_kds_start_ready_serve_workflow.sql',
      'scripts/verify_kds_start_ready_serve_workflow.sql',
      'scripts/rollback_kds_start_ready_serve_workflow.sql',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
  });

  test(
    'migration keeps kitchen and tray handoffs atomic and batch-idempotent',
    () {
      final migration = File(
        'supabase/migrations/20260917150000_kds_kitchen_complete_tray_handoff_batch.sql',
      ).readAsStringSync();
      expect(migration, contains("v_action = 'kitchen_done'"));
      expect(migration, contains("v_action = 'tray_dispatched'"));
      expect(migration, contains('tray_received_quantity = v_received'));
      expect(migration, contains('tray_dispatched_quantity = v_dispatched'));
      expect(migration, contains('emergency_tray_ready_lots'));
      expect(migration, contains('emergency_floor_ready_lots'));
      expect(migration, contains('kds_complete_kitchen_batch_v1'));
      expect(migration, contains('allocation_hash'));
      expect(migration, contains('oldest_tray_ready_sequence'));
    },
  );

  test('checket groups quantities and allocates the earliest orders first', () {
    final base = DateTime.utc(2026, 9, 17, 10);
    final later = _order(
      id: 'later',
      queueNo: 2,
      createdAt: base.add(const Duration(minutes: 1)),
      item: _item(id: 'later-item', ordered: 3, nameKo: '김밥'),
    );
    final earlier = _order(
      id: 'earlier',
      queueNo: 1,
      createdAt: base,
      item: _item(id: 'earlier-item', ordered: 2, nameKo: '김밥'),
    );
    final groups = buildKitchenChecketMenuGroups([later, earlier]);
    expect(groups.single.pendingQuantity, 5);
    final allocations = allocateKitchenChecketSelections(
      [later, earlier],
      {groups.single.key: 3},
    );
    expect(
      allocations.map((allocation) => (allocation.itemId, allocation.quantity)),
      [('earlier-item', 2), ('later-item', 1)],
    );
  });

  test(
    'screen contains fixed floor border colors and ready-only bulk action',
    () {
      final screen = File(
        'lib/features/emergency_fulfillment/emergency_fulfillment_screen.dart',
      ).readAsStringSync();
      expect(screen, contains("'1F' => const Color(0xFF1976D2)"));
      expect(screen, contains("'2F' => const Color(0xFFD32F2F)"));
      expect(screen, contains("Key('emergency_serve_ready_order')"));
      expect(screen, contains('readyFromPreviousStage &&'));
    },
  );
}
