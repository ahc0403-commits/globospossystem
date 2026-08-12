import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/qr_order_service.dart';

void main() {
  test('paperless active order parses bounded delivery progress fields', () {
    final order = QrActiveOrder.fromJson({
      'active': true,
      'order_code': 'abcd1234',
      'status': 'serving',
      'fulfillment_mode': 'paperless',
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
}
