import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';

EmergencyFulfillmentItem _item({
  String id = 'item-1',
  int ordered = 2,
  int started = 0,
  int ready = 0,
  int served = 0,
  int excused = 0,
  int? readySequence,
  String route = 'kitchen_tray_floor',
}) => EmergencyFulfillmentItem(
  id: id,
  orderItemId: 'order-$id',
  nameKo: '메뉴',
  nameVi: 'Món',
  nameEn: 'Item',
  orderedQuantity: ordered,
  kitchenStartedQuantity: started,
  kitchenDoneQuantity: ready,
  trayReceivedQuantity: ready,
  trayDispatchedQuantity: ready,
  floorServedQuantity: served,
  excusedQuantity: excused,
  needsReview: false,
  workflowVersion: 2,
  fulfillmentRoute: route,
  oldestReadySequence: readySequence,
);

EmergencyFulfillmentOrder _order({
  required String id,
  required int queueNo,
  required DateTime createdAt,
  int? readySequence,
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
);

void main() {
  test('v2 preserves start, ready and served as separate quantities', () {
    final waiting = _item();
    expect(waiting.isActionableAt('kitchen'), isTrue);
    expect(waiting.isActionableAt('tray'), isFalse);

    final started = waiting.withStage('kitchen_started', 1);
    expect(started.kitchenStartedQuantity, 1);
    expect(started.kitchenDoneQuantity, 0);
    expect(started.isActionableAt('tray'), isTrue);

    final ready = started.withStage('tray_ready', 1);
    expect(ready.kitchenDoneQuantity, 1);
    expect(ready.trayReceivedQuantity, 1);
    expect(ready.trayDispatchedQuantity, 1);
    expect(ready.readyUnservedQuantity, 1);

    final served = ready.withStage('floor_served', 1);
    expect(served.readyUnservedQuantity, 0);
    expect(served.isActionableAt('floor'), isFalse);
  });

  test('kitchen card completes only after tray marks every item ready', () {
    final receivedAt = DateTime.utc(2026, 9, 16, 10);
    final startedOrder = _order(
      id: 'A',
      queueNo: 1,
      createdAt: receivedAt,
      item: _item(started: 2),
    );
    expect(startedOrder.hasActionableQuantity('kitchen'), isFalse);
    expect(startedOrder.isRecentlyCompleteAt('kitchen'), isFalse);

    final readyOrder = startedOrder.copyWith(
      items: [_item(started: 2, ready: 2)],
    );
    expect(readyOrder.isRecentlyCompleteAt('kitchen'), isTrue);
    expect(readyOrder.isRecentlyCompleteAt('tray'), isTrue);
  });

  test('cashier-excused remainder closes work without erasing service', () {
    final item = _item(ordered: 3, started: 1, ready: 1, served: 1, excused: 2);
    expect(item.requiredQuantity, 1);
    expect(item.floorServedQuantity, 1);
    expect(item.isCompletedAt('floor'), isTrue);
    expect(item.isActionableAt('kitchen'), isFalse);
    expect(item.readyUnservedQuantity, 0);
  });

  test(
    'kitchen and tray remain arrival FIFO while floor uses ready sequence',
    () {
      final base = DateTime.utc(2026, 9, 16, 10);
      final a = _order(id: 'A', queueNo: 1, createdAt: base, readySequence: 20);
      final b = _order(
        id: 'B',
        queueNo: 2,
        createdAt: base.add(const Duration(minutes: 1)),
      );
      final c = _order(
        id: 'C',
        queueNo: 3,
        createdAt: base.add(const Duration(minutes: 2)),
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
        ['A', 'B', 'C'],
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
            .withStage('kitchen_started', 1)
            .withStage('tray_ready', 1)
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
    'partially ready tray line remains pending until every started unit is ready',
    () {
      final partial = _item(started: 2, ready: 1);
      expect(partial.isDisplayCompletedAt('tray'), isFalse);
      expect(partial.isReadyFromPreviousStageAt('tray'), isTrue);
      expect(
        partial.withStage('tray_ready', 2).isDisplayCompletedAt('tray'),
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
