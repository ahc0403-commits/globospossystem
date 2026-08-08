import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/order/order_model.dart';

void main() {
  test('order item keeps Vietnamese and English menu names', () {
    final item = OrderItem.fromJson({
      'id': 'item-1',
      'menu_item_id': 'menu-1',
      'label': '김밥',
      'unit_price': 39000,
      'quantity': 1,
      'status': 'ready',
      'item_type': 'menu_item',
      'menu_items': {
        'name': '김밥',
        'name_vi': 'Cơm cuộn Hàn Quốc',
        'name_en': 'Korean rice roll',
      },
    });

    expect(item.label, '김밥');
    expect(item.nameVi, 'Cơm cuộn Hàn Quốc');
    expect(item.nameEn, 'Korean rice roll');
  });

  test('floor order item keeps snapshotted combo drink selections', () {
    final item = OrderItem.fromJson({
      'id': 'item-combo',
      'menu_item_id': 'combo-3',
      'label': 'Combo 3',
      'unit_price': 199000,
      'quantity': 2,
      'status': 'pending',
      'item_type': 'menu_item',
      'combo_components': [
        {'label': 'Kimbap', 'quantity': 1},
        {'label': 'Cola', 'quantity': 1, 'is_total_quantity': true},
        {'label': 'Water', 'quantity': 1, 'is_total_quantity': true},
      ],
    });

    expect(item.comboComponents, hasLength(3));
    expect(item.comboComponents.first.displayQuantity(item.quantity), 2);
    expect(item.comboComponents[1].displayQuantity(item.quantity), 1);
    expect(item.comboComponents[2].label, 'Water');
  });

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

  test(
    'floor order query and both floor order views include combo snapshots',
    () {
      final provider = File(
        'lib/features/order/order_provider.dart',
      ).readAsStringSync();
      final workspace = File(
        'lib/widgets/order_workspace.dart',
      ).readAsStringSync();

      expect(provider, contains('item_type, combo_components, menu_items'));
      expect(workspace, contains('order_sent_item_combo_components_'));
      expect(workspace, contains('order_current_ticket_combo_components_'));
      expect(workspace, contains('component.displayQuantity(item.quantity)'));
    },
  );
}
