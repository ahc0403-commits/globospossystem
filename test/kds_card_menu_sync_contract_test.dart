import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/digital_receipt_pdf_service.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';

void main() {
  test('elapsed clock uses total minutes and two-digit seconds', () {
    expect(formatEmergencyElapsed(const Duration()), '00:00');
    expect(formatEmergencyElapsed(const Duration(seconds: 1)), '00:01');
    expect(
      formatEmergencyElapsed(const Duration(minutes: 59, seconds: 59)),
      '59:59',
    );
    expect(formatEmergencyElapsed(const Duration(minutes: 60)), '60:00');
    expect(formatEmergencyElapsed(const Duration(seconds: -1)), '00:00');
  });

  test('combo components are parsed as separate display lines', () {
    final item = EmergencyFulfillmentItem.fromJson({
      'id': 'base-1',
      'order_item_id': 'order-item-1',
      'name_ko': '세트 A',
      'name_vi': 'Combo A',
      'name_en': 'Combo A',
      'ordered_quantity': 1,
      'kitchen_done_quantity': 1,
      'tray_received_quantity': 0,
      'tray_dispatched_quantity': 0,
      'floor_served_quantity': 0,
      'needs_review': false,
      'combo_components': [
        {
          'menu_item_id': 'food-1',
          'name_ko': '김밥',
          'name_vi': 'Cơm cuộn',
          'name_en': 'Gimbap',
          'quantity': 1,
          'fulfillment_route': 'kitchen_tray_floor',
        },
        {
          'menu_item_id': 'drink-1',
          'name_ko': '콜라',
          'name_vi': 'Coca-Cola',
          'name_en': 'Cola',
          'quantity': 1,
          'fulfillment_route': 'floor_direct',
        },
      ],
    });

    expect(item.comboComponents, hasLength(2));
    expect(item.comboComponents.map((component) => component.nameVi), [
      'Cơm cuộn',
      'Coca-Cola',
    ]);
  });

  test('combo card expands components without duplicating direct drinks', () {
    final order = EmergencyFulfillmentOrder.fromJson({
      'queue_id': 'queue-1',
      'order_id': 'order-1',
      'queue_no': 1,
      'table_number': '102',
      'floor_label': '1F',
      'created_at': '2026-08-15T02:00:00Z',
      'items': [
        {
          'id': 'base-1',
          'order_item_id': 'order-item-1',
          'name_ko': '세트 A',
          'name_vi': 'Combo A',
          'name_en': 'Combo A',
          'ordered_quantity': 1,
          'kitchen_done_quantity': 1,
          'tray_received_quantity': 0,
          'tray_dispatched_quantity': 0,
          'floor_served_quantity': 0,
          'combo_components': [
            {
              'menu_item_id': 'food-1',
              'name_ko': '김밥',
              'name_vi': 'Cơm cuộn',
              'name_en': 'Gimbap',
              'quantity': 1,
              'fulfillment_route': 'kitchen_tray_floor',
            },
            {
              'menu_item_id': 'drink-1',
              'name_ko': '콜라',
              'name_vi': 'Coca-Cola',
              'name_en': 'Cola',
              'quantity': 1,
              'fulfillment_route': 'floor_direct',
            },
          ],
        },
        {
          'id': 'direct-1',
          'order_item_id': 'order-item-1',
          'name_ko': '콜라',
          'name_vi': 'Coca-Cola',
          'name_en': 'Cola',
          'ordered_quantity': 1,
          'kitchen_done_quantity': 0,
          'tray_received_quantity': 0,
          'tray_dispatched_quantity': 0,
          'floor_served_quantity': 0,
          'fulfillment_route': 'floor_direct',
          'line_key': 'combo:drink-1',
          'source_kind': 'combo_component',
        },
      ],
    });

    final kitchenLines = order.displayItemsAt('kitchen');
    expect(kitchenLines.map((item) => item.nameVi), ['Cơm cuộn', 'Coca-Cola']);
    expect(kitchenLines.map((item) => item.completed), [true, false]);
    expect(kitchenLines.map((item) => item.readOnly), [false, true]);
  });

  test('additive SQL exposes today completed orders and combo snapshots', () {
    final migration = File(
      'supabase/migrations/20260815170000_kds_card_menu_sync.sql',
    ).readAsStringSync();

    expect(migration, contains('get_emergency_station_today_completed'));
    expect(migration, contains("AT TIME ZONE 'Asia/Ho_Chi_Minh'"));
    expect(migration, contains("'combo_components'"));
    expect(migration, contains('emergency_fulfillment_actions'));
    expect(migration, contains('emergency_fulfillment_events'));
  });

  test('digital receipt migration snapshots Vietnamese menu names', () {
    final migration = File(
      'supabase/migrations/20260815171000_digital_receipt_vietnamese.sql',
    ).readAsStringSync();

    expect(migration, contains('name_vi'));
    expect(migration, contains("'Món'"));
    expect(migration, contains('ensure_digital_receipt'));
  });

  test('PDF payment codes and unsafe fallbacks resolve to Vietnamese', () {
    expect(digitalReceiptPaymentMethodVi('CASH'), 'Tiền mặt');
    expect(digitalReceiptPaymentMethodVi('BANKTRANSFER'), 'Chuyển khoản');
    expect(digitalReceiptPaymentMethodVi('SPLIT'), 'Thanh toán kết hợp');
    expect(digitalReceiptPaymentMethodVi('unknown'), 'Khác');
    expect(digitalReceiptItemLabelVi('Item'), 'Món');
    expect(digitalReceiptItemLabelVi('떡볶이'), 'Món');
    expect(digitalReceiptItemLabelVi('Bánh gạo cay'), 'Bánh gạo cay');
  });
}
