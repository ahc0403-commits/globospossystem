import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/qr_order_service.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';
import 'package:globos_pos_system/features/order/order_model.dart';

void main() {
  test('takeout remains an immutable line-level choice', () {
    const line = QrOrderLine(
      menuItemId: 'menu-1',
      quantity: 2,
      isTakeout: true,
    );
    expect(line.toJson(), {
      'menu_item_id': 'menu-1',
      'quantity': 2,
      'is_takeout': true,
    });

    const dineIn = CartItem(
      menuItemId: 'menu-1',
      name: 'Menu',
      price: 100,
      quantity: 1,
    );
    final takeout = dineIn.copyWith(isTakeout: true);
    expect(dineIn.lineKey, isNot(takeout.lineKey));
  });

  test('staff active order parses takeout and one leftover request', () {
    final order = Order.fromJson({
      'id': 'order-1',
      'table_id': 'table-1',
      'status': 'serving',
      'created_at': '2026-08-23T00:00:00Z',
      'leftover_packaging_requests': [
        {'status': 'awaiting_floor_pickup'},
      ],
      'order_items': [
        {
          'id': 'item-1',
          'menu_item_id': 'menu-1',
          'quantity': 1,
          'unit_price': 100,
          'is_takeout': true,
        },
      ],
    });

    expect(order.items.single.isTakeout, isTrue);
    expect(order.leftoverPackagingStatus, 'awaiting_floor_pickup');
  });

  test('paperless snapshot exposes only the current packaging task', () {
    final state = EmergencyFulfillmentState.fromJson({
      'assigned': true,
      'active': true,
      'station_type': 'kitchen',
      'orders': [
        {
          'queue_id': 'queue-1',
          'order_id': 'order-1',
          'queue_no': 1,
          'table_number': '12',
          'floor_label': '2F',
          'created_at': '2026-08-23T00:00:00Z',
          'items': [
            {
              'id': 'fulfillment-1',
              'order_item_id': 'item-1',
              'name_vi': 'Món ăn',
              'ordered_quantity': 1,
              'is_takeout': true,
            },
          ],
        },
      ],
      'leftover_packaging_tasks': [
        {
          'id': 'request-1',
          'order_id': 'order-1',
          'queue_id': 'queue-1',
          'queue_no': 1,
          'table_number': '12',
          'floor_label': '2F',
          'status': 'awaiting_kitchen_packaging',
          'requested_at': '2026-08-23T00:00:00Z',
        },
      ],
    });

    expect(
      state.leftoverPackagingTasks.single.status,
      'awaiting_kitchen_packaging',
    );
    expect(
      state.orders.single.displayItemsAt('kitchen').single.isTakeout,
      isTrue,
    );
  });

  test('migration enforces the reverse round trip and no sale-line shortcut', () {
    final migration = File(
      'supabase/migrations/20260823010000_takeout_leftover_packaging.sql',
    ).readAsStringSync();

    expect(migration, contains('ADD COLUMN IF NOT EXISTS is_takeout boolean'));
    expect(migration, contains('UNIQUE (order_id)'));
    expect(migration, contains("'awaiting_floor_pickup', 'floor'"));
    expect(migration, contains("'awaiting_tray_to_kitchen', 'tray'"));
    expect(migration, contains("'awaiting_kitchen_packaging', 'kitchen'"));
    expect(migration, contains("'awaiting_tray_return', 'tray'"));
    expect(migration, contains("'awaiting_floor_delivery', 'floor'"));
    expect(
      'LEFTOVER_PACKAGING_REQUEST_CONFLICT'.allMatches(migration),
      hasLength(2),
    );
    expect(
      migration,
      contains("'floor', v_queue.floor_label, 'leftover_requested'"),
    );
    expect(
      migration,
      contains("request.status = 'awaiting_kitchen_packaging'"),
    );
    expect(
      migration,
      contains(
        "request.status IN ('awaiting_floor_pickup', 'awaiting_floor_delivery')",
      ),
    );
    expect(migration, isNot(contains("item_type', 'leftover")));
  });
}
