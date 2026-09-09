import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/qr_order_service.dart';

void main() {
  test('paperless active order parses bounded delivery progress fields', () {
    final order = QrActiveOrder.fromJson({
      'active': true,
      'order_id': 'f1000000-0000-4000-8000-000000000001',
      'order_code': 'abcd1234',
      'status': 'serving',
      'fulfillment_mode': 'paperless',
      'display_version': 3,
      'display_reset_at': '2026-09-09T12:10:00Z',
      'reset_due_at': '2026-09-09T12:20:00Z',
      'items': [
        {
          'name': 'Tteokbokki',
          'quantity': 5,
          'status': 'ready',
          'served_quantity': 4,
          'fulfillment_parts': [
            {
              'line_key': 'base',
              'name': 'Tteokbokki',
              'quantity': 5,
              'served_quantity': 4,
              'fulfillment_route': 'kitchen_tray_floor',
            },
            {
              'line_key': 'combo:cola',
              'name': 'Cola',
              'quantity': 2,
              'served_quantity': 1,
              'fulfillment_route': 'floor_direct',
            },
          ],
        },
      ],
    });

    expect(order.isPaperless, isTrue);
    expect(order.orderId, 'f1000000-0000-4000-8000-000000000001');
    expect(order.displayVersion, 3);
    expect(order.displayResetAt, DateTime.utc(2026, 9, 9, 12, 10));
    expect(order.resetDueAt, DateTime.utc(2026, 9, 9, 12, 20));
    expect(order.items.single.servedQuantity, 4);
    expect(order.items.single.remainingQuantity, 1);
    expect(order.items.single.fulfillmentParts, hasLength(2));
    expect(order.items.single.fulfillmentParts.last.name, 'Cola');
    expect(order.items.single.fulfillmentParts.last.remainingQuantity, 1);
  });

  test('legacy and printed responses default to list-only mode', () {
    final order = QrActiveOrder.fromJson({
      'active': true,
      'items': [
        {'name': 'Pho', 'quantity': 2, 'status': 'served'},
      ],
    });

    expect(order.isPaperless, isFalse);
    expect(order.items.single.servedQuantity, 0);
    expect(order.items.single.remainingQuantity, 2);
  });

  test('completed-order marker is parsed without exposing an active order', () {
    final order = QrActiveOrder.fromJson({
      'active': false,
      'last_closed_order_id': 'f1000000-0000-4000-8000-000000000099',
      'items': <Object>[],
    });

    expect(order.isActive, isFalse);
    expect(order.lastClosedOrderId, 'f1000000-0000-4000-8000-000000000099');
  });
}
