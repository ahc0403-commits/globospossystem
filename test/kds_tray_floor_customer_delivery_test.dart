import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/emergency_web_bridge.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';

void main() {
  group('tray floor transition model', () {
    test('splits floors, aggregates names, and preserves FIFO allocations', () {
      final orders = [
        _order(
          queueId: 'queue-old',
          orderId: 'order-old',
          floor: '1F',
          createdAt: DateTime.utc(2026, 9, 18, 10),
          items: [_item(id: 'old-gimbap', name: '김밥', done: 2, dispatched: 0)],
        ),
        _order(
          queueId: 'queue-new',
          orderId: 'order-new',
          floor: '1F',
          createdAt: DateTime.utc(2026, 9, 18, 11),
          items: [
            _item(id: 'new-gimbap', name: '김밥', done: 3, dispatched: 1),
            _item(
              id: 'review',
              name: '김치찌개',
              done: 1,
              dispatched: 0,
              needsReview: true,
            ),
            _item(
              id: 'direct',
              name: '콜라',
              done: 1,
              dispatched: 0,
              route: 'floor_direct',
            ),
          ],
        ),
        _order(
          queueId: 'queue-second',
          orderId: 'order-second',
          floor: '2F',
          createdAt: DateTime.utc(2026, 9, 18, 9),
          items: [_item(id: 'second', name: '라면', done: 4, dispatched: 1)],
        ),
        _order(
          queueId: 'queue-delivery',
          orderId: 'order-delivery',
          floor: '1F',
          createdAt: DateTime.utc(2026, 9, 18, 8),
          salesChannel: 'delivery',
          items: [_item(id: 'delivery', name: '배달', done: 5, dispatched: 0)],
        ),
      ];

      final first = buildTrayFloorTransitionSummary(orders, '1F');
      final second = buildTrayFloorTransitionSummary(orders, '2F');

      expect(first.totalQuantity, 4);
      expect(first.groups, hasLength(1));
      expect(first.groups.single.quantity, 4);
      expect(first.allocations.map((allocation) => allocation.itemId), [
        'old-gimbap',
        'new-gimbap',
      ]);
      final selected = allocateTrayFloorTransitionSelections(first, {
        first.groups.single.key: 3,
      });
      expect(selected.totalQuantity, 3);
      expect(selected.allocations.map((allocation) => allocation.quantity), [
        2,
        1,
      ]);
      expect(second.totalQuantity, 3);
      expect(second.allocations.single.itemId, 'second');
    });

    test(
      'tray ready sorting returns to received FIFO after acknowledgement',
      () {
        final old = _order(
          queueId: 'queue-old',
          orderId: 'order-old',
          floor: '1F',
          createdAt: DateTime.utc(2026, 9, 18, 10),
          items: [_item(id: 'old', name: '김밥', done: 0, dispatched: 0)],
        );
        final newestReady = _order(
          queueId: 'queue-new',
          orderId: 'order-new',
          floor: '1F',
          createdAt: DateTime.utc(2026, 9, 18, 11),
          oldestTrayReadySequence: 1,
          items: [_item(id: 'new', name: '라면', done: 1, dispatched: 0)],
        );

        expect(
          sortEmergencyOrdersForStation([
            old,
            newestReady,
          ], 'tray').first.orderId,
          'order-new',
        );
        expect(
          sortEmergencyOrdersForStation([
            old,
            newestReady.copyWith(clearOldestTrayReadySequence: true),
          ], 'tray').first.orderId,
          'order-old',
        );
      },
    );
  });

  group('customer delivery model', () {
    test('uses only tray-delivered unserved food on the assigned floor', () {
      final orders = [
        _order(
          queueId: 'queue-1',
          orderId: 'order-1',
          floor: '1F',
          createdAt: DateTime.utc(2026, 9, 18, 10),
          oldestReadySequence: 2,
          items: [
            _item(id: 'item-1', name: '김밥', done: 5, dispatched: 4, served: 1),
            _item(id: 'not-arrived', name: '라면', done: 2, dispatched: 0),
            _item(
              id: 'direct',
              name: '콜라',
              done: 1,
              dispatched: 1,
              route: 'floor_direct',
            ),
          ],
        ),
        _order(
          queueId: 'queue-2',
          orderId: 'order-2',
          floor: '2F',
          createdAt: DateTime.utc(2026, 9, 18, 9),
          items: [_item(id: 'other-floor', name: '라면', done: 2, dispatched: 2)],
        ),
      ];

      final boxes = buildCustomerDeliveryBoxes(orders, '1F');

      expect(boxes, hasLength(1));
      expect(boxes.single.tableNumber, 'T1');
      expect(boxes.single.menus, hasLength(1));
      expect(boxes.single.menus.single.availableQuantity, 3);
      final allocations = allocateCustomerDeliverySelections(boxes, {
        boxes.single.menus.single.key: 2,
      });
      expect(allocations.single.itemId, 'item-1');
      expect(allocations.single.quantity, 2);
    });

    test('rejects a selection above the captured available quantity', () {
      final boxes = buildCustomerDeliveryBoxes([
        _order(
          queueId: 'queue-1',
          orderId: 'order-1',
          floor: '1F',
          createdAt: DateTime.utc(2026, 9, 18, 10),
          items: [_item(id: 'item-1', name: '김밥', done: 2, dispatched: 2)],
        ),
      ], '1F');

      expect(
        () => allocateCustomerDeliverySelections(boxes, {
          boxes.single.menus.single.key: 3,
        }),
        throwsStateError,
      );
    });
  });

  test('batch outbox records preserve every pending queue after reload', () {
    final queueIds = emergencyPendingQueueIds([
      EmergencyOutboxRecord(
        id: 'tray-request',
        payload: jsonEncode({
          'kind': 'tray_floor_batch',
          'allocations': [
            {'queue_id': 'queue-1'},
            {'queue_id': 'queue-2'},
          ],
        }),
      ),
      EmergencyOutboxRecord(
        id: 'customer-request',
        payload: jsonEncode({
          'kind': 'customer_delivery_batch',
          'allocations': [
            {'queue_id': 'queue-2'},
            {'queue_id': 'queue-3'},
          ],
        }),
      ),
      EmergencyOutboxRecord(
        id: 'legacy-request',
        payload: jsonEncode({'queue_id': 'queue-4'}),
      ),
      const EmergencyOutboxRecord(id: 'invalid', payload: '{'),
    ]);

    expect(queueIds, {'queue-1', 'queue-2', 'queue-3', 'queue-4'});
  });

  test('batch migration keeps atomic stale and production gate contracts', () {
    const migrationPath =
        'supabase/migrations/20260918010000_kds_tray_floor_customer_delivery_batches.sql';
    final migration = File(migrationPath).readAsStringSync();

    expect(migration, contains('-- production-gate: self-verifying'));
    expect(migration, contains('kds_dispatch_tray_floor_batch_v1'));
    expect(migration, contains('kds_complete_customer_delivery_batch_v1'));
    expect(migration, contains('KDS_TRAY_FLOOR_BATCH_STALE'));
    expect(migration, contains('KDS_CUSTOMER_DELIVERY_BATCH_STALE'));
    expect(migration, contains('FOR UPDATE OF component, queue NOWAIT'));
    expect(migration, contains('FOR UPDATE OF item, queue NOWAIT'));
    expect(
      migration.toLowerCase(),
      isNot(contains('insert into public.payments')),
    );

    for (final path in [
      'scripts/preflight_kds_tray_floor_customer_delivery_batches.sql',
      'scripts/verify_kds_tray_floor_customer_delivery_batches.sql',
      'scripts/rollback_kds_tray_floor_customer_delivery_batches.sql',
      'supabase/tests/kds_tray_floor_customer_delivery_batches_test.sql',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }

    const partialMigrationPath =
        'supabase/migrations/20260919010000_kds_tray_floor_partial_batch.sql';
    final partialMigration = File(partialMigrationPath).readAsStringSync();
    expect(
      partialMigration,
      contains('current_line.quantity >= allocation.quantity'),
    );
    expect(partialMigration, contains('KDS_TRAY_FLOOR_BATCH_STALE'));
    expect(partialMigration, contains('pg_advisory_xact_lock'));
    expect(
      partialMigration.toLowerCase(),
      isNot(contains('insert into public.payments')),
    );
    for (final path in [
      'scripts/preflight_kds_tray_floor_partial_batch.sql',
      'scripts/verify_kds_tray_floor_partial_batch.sql',
      'scripts/rollback_kds_tray_floor_partial_batch.sql',
      'scripts/test_kds_tray_floor_partial_batch.sh',
      'test/fixtures/kds_tray_floor_partial_batch_setup.sql',
      'supabase/tests/kds_tray_floor_partial_batch_test.sql',
      'supabase/tests/kds_tray_floor_customer_delivery_batches_test.sql',
    ]) {
      expect(File(path).existsSync(), isTrue, reason: path);
    }
  });
}

EmergencyFulfillmentItem _item({
  required String id,
  required String name,
  required int done,
  required int dispatched,
  int served = 0,
  bool needsReview = false,
  String route = 'kitchen_tray_floor',
}) => EmergencyFulfillmentItem(
  id: id,
  orderItemId: 'order-$id',
  nameKo: name,
  nameVi: name,
  nameEn: name,
  orderedQuantity: 10,
  kitchenStartedQuantity: done,
  kitchenDoneQuantity: done,
  trayReceivedQuantity: dispatched,
  trayDispatchedQuantity: dispatched,
  floorServedQuantity: served,
  needsReview: needsReview,
  workflowVersion: 2,
  fulfillmentRoute: route,
);

EmergencyFulfillmentOrder _order({
  required String queueId,
  required String orderId,
  required String floor,
  required DateTime createdAt,
  required List<EmergencyFulfillmentItem> items,
  String salesChannel = 'dine_in',
  int? oldestReadySequence,
  int? oldestTrayReadySequence,
}) => EmergencyFulfillmentOrder(
  queueId: queueId,
  orderId: orderId,
  queueNo: 1,
  tableNumber: 'T1',
  floorLabel: floor,
  createdAt: createdAt,
  items: items,
  salesChannel: salesChannel,
  workflowVersion: 2,
  oldestReadySequence: oldestReadySequence,
  oldestTrayReadySequence: oldestTrayReadySequence,
);
