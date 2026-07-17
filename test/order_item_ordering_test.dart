import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/order/order_model.dart';

void main() {
  test('order items are displayed in oldest-to-newest creation order', () {
    final order = Order.fromJson({
      'id': 'order-1',
      'table_id': 'table-1',
      'status': 'pending',
      'created_at': '2026-05-21T10:00:00Z',
      'order_items': [
        {
          'id': 'item-3',
          'menu_item_id': 'menu-3',
          'label': 'Third item',
          'unit_price': 3000,
          'quantity': 1,
          'status': 'pending',
          'item_type': 'menu',
          'created_at': '2026-05-21T10:02:00Z',
        },
        {
          'id': 'item-1',
          'menu_item_id': 'menu-1',
          'label': 'First item',
          'unit_price': 1000,
          'quantity': 1,
          'status': 'pending',
          'item_type': 'menu',
          'created_at': '2026-05-21T10:00:00Z',
        },
        {
          'id': 'item-2',
          'menu_item_id': 'menu-2',
          'label': 'Second item',
          'unit_price': 2000,
          'quantity': 1,
          'status': 'pending',
          'item_type': 'menu',
          'created_at': '2026-05-21T10:01:00Z',
        },
      ],
    });

    expect(order.items.map((item) => item.label), [
      'First item',
      'Second item',
      'Third item',
    ]);
  });

  test('order item queries request oldest-to-newest nested item ordering', () {
    final files = [
      'lib/features/order/order_provider.dart',
      'lib/features/kitchen/kitchen_provider.dart',
      'lib/features/payment/payment_provider.dart',
      'lib/features/table/table_provider.dart',
      'lib/core/services/payment_service.dart',
    ];

    for (final path in files) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        matches(
          RegExp(
            r"\.order\(\s*'created_at'\s*,\s*referencedTable:\s*'order_items'\s*,\s*ascending:\s*true\s*,?\s*\)",
          ),
        ),
        reason: path,
      );
    }
  });
}
