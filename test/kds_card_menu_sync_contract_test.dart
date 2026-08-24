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

  test('initial and supplemental batches keep independent station clocks', () {
    final initialReceivedAt = DateTime.utc(2026, 8, 24, 10);
    final addedReceivedAt = DateTime.utc(2026, 8, 24, 10, 30);
    final order = EmergencyFulfillmentOrder(
      queueId: 'queue-1',
      orderId: 'order-1',
      queueNo: 1,
      tableNumber: '101',
      floorLabel: '1F',
      createdAt: initialReceivedAt,
      items: [
        EmergencyFulfillmentItem.fromJson({
          'id': 'initial-1',
          'order_item_id': 'order-item-initial-1',
          'name_ko': '떡볶이',
          'name_vi': 'Bánh gạo cay',
          'name_en': 'Spicy rice cake',
          'ordered_quantity': 1,
          'kitchen_done_quantity': 1,
          'tray_received_quantity': 0,
          'tray_dispatched_quantity': 0,
          'floor_served_quantity': 0,
          'needs_review': false,
          'batch_received_at': initialReceivedAt.toIso8601String(),
          'kitchen_first_done_at': DateTime.utc(
            2026,
            8,
            24,
            10,
            4,
          ).toIso8601String(),
          'kitchen_last_done_at': DateTime.utc(
            2026,
            8,
            24,
            10,
            5,
          ).toIso8601String(),
        }),
        for (final id in ['added-1', 'added-2'])
          EmergencyFulfillmentItem.fromJson({
            'id': id,
            'order_item_id': 'order-item-$id',
            'name_ko': '김밥',
            'name_vi': 'Cơm cuộn',
            'name_en': 'Gimbap',
            'ordered_quantity': 1,
            'kitchen_done_quantity': 0,
            'tray_received_quantity': 0,
            'tray_dispatched_quantity': 0,
            'floor_served_quantity': 0,
            'needs_review': false,
            'batch_received_at': addedReceivedAt.toIso8601String(),
          }),
      ],
    );

    final batches = order.stationBatchesAt('kitchen');
    expect(batches, hasLength(2));
    expect(batches.first.isSupplemental, isFalse);
    expect(
      batches.first.elapsedAt(DateTime.utc(2026, 8, 24, 11)),
      const Duration(minutes: 5),
    );
    expect(batches.last.isSupplemental, isTrue);
    expect(batches.last.items, hasLength(2));
    expect(
      batches.last.elapsedAt(DateTime.utc(2026, 8, 24, 10, 33)),
      const Duration(minutes: 3),
    );
  });

  test('fast refresh preserves tray and floor station timer boundaries', () {
    EmergencyFulfillmentState state({
      required String sessionId,
      required String stationType,
      DateTime? stationStartedAt,
    }) => EmergencyFulfillmentState(
      sessionId: sessionId,
      stationType: stationType,
      orders: [
        EmergencyFulfillmentOrder(
          queueId: 'queue-1',
          orderId: 'order-1',
          queueNo: 1,
          tableNumber: '101',
          floorLabel: '1F',
          createdAt: DateTime.utc(2026, 8, 19, 10),
          stationStartedAt: stationStartedAt,
          items: const [],
        ),
      ],
    );

    final startedAt = DateTime.utc(2026, 8, 19, 10, 5);
    for (final stationType in ['tray', 'floor']) {
      final previous = state(
        sessionId: 'session-1',
        stationType: stationType,
        stationStartedAt: startedAt,
      );
      final fastSnapshot = state(
        sessionId: 'session-1',
        stationType: stationType,
      );
      expect(
        preserveEmergencyStationTimings(
          fastSnapshot,
          previous,
        ).orders.single.stationStartedAt,
        startedAt,
      );
    }
    final previous = state(
      sessionId: 'session-1',
      stationType: 'floor',
      stationStartedAt: startedAt,
    );
    expect(
      preserveEmergencyStationTimings(
        state(sessionId: 'session-2', stationType: 'floor'),
        previous,
      ).orders.single.stationStartedAt,
      isNull,
    );
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
          'id': 'food-1-progress',
          'order_item_id': 'order-item-1',
          'name_ko': '김밥',
          'name_vi': 'Cơm cuộn',
          'name_en': 'Gimbap',
          'ordered_quantity': 1,
          'kitchen_done_quantity': 1,
          'tray_received_quantity': 0,
          'tray_dispatched_quantity': 0,
          'floor_served_quantity': 0,
          'fulfillment_route': 'kitchen_tray_floor',
          'line_key': 'combo:food-1',
          'source_kind': 'combo_component',
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
    expect(kitchenLines.map((item) => item.nameVi), ['Cơm cuộn']);
    expect(kitchenLines.map((item) => item.fulfillmentItemId), [
      'food-1-progress',
    ]);
    expect(kitchenLines.map((item) => item.completed), [true]);
    expect(kitchenLines.map((item) => item.readyFromPreviousStage), [false]);
    expect(kitchenLines.map((item) => item.readOnly), [false]);

    final trayLines = order.displayItemsAt('tray');
    expect(trayLines.map((item) => item.nameVi), ['Cơm cuộn']);
    expect(order.incomingHandoffQuantityAt('tray'), 1);

    final floorLines = order.displayItemsAt('floor');
    expect(floorLines.map((item) => item.nameVi), ['Cơm cuộn', 'Coca-Cola']);
    expect(floorLines.map((item) => item.fulfillmentItemId), [
      'food-1-progress',
      'direct-1',
    ]);
  });

  test('combo components own independent completion and sorting state', () {
    final order = EmergencyFulfillmentOrder.fromJson({
      'queue_id': 'queue-independent',
      'order_id': 'order-independent',
      'queue_no': 2,
      'table_number': '104',
      'floor_label': '1F',
      'created_at': '2026-08-16T02:00:00Z',
      'items': [
        {
          'id': 'combo-parent',
          'order_item_id': 'combo-order-item',
          'ordered_quantity': 1,
          'kitchen_done_quantity': 0,
          'tray_received_quantity': 0,
          'tray_dispatched_quantity': 0,
          'floor_served_quantity': 0,
          'combo_components': [
            {
              'menu_item_id': 'food-1',
              'name_vi': 'Tteokbokki',
              'quantity': 1,
              'fulfillment_route': 'kitchen_tray_floor',
            },
            {
              'menu_item_id': 'food-2',
              'name_vi': 'Kimbap',
              'quantity': 1,
              'fulfillment_route': 'kitchen_tray_floor',
            },
          ],
        },
        {
          'id': 'food-1-progress',
          'order_item_id': 'combo-order-item',
          'line_key': 'combo:food-1',
          'source_kind': 'combo_component',
          'ordered_quantity': 1,
          'kitchen_done_quantity': 1,
          'tray_received_quantity': 0,
          'tray_dispatched_quantity': 0,
          'floor_served_quantity': 0,
        },
        {
          'id': 'food-2-progress',
          'order_item_id': 'combo-order-item',
          'line_key': 'combo:food-2',
          'source_kind': 'combo_component',
          'ordered_quantity': 1,
          'kitchen_done_quantity': 0,
          'tray_received_quantity': 0,
          'tray_dispatched_quantity': 0,
          'floor_served_quantity': 0,
        },
      ],
    });

    final lines = order.displayItemsAt('kitchen');
    expect(lines.map((item) => item.nameVi), ['Kimbap', 'Tteokbokki']);
    expect(lines.map((item) => item.fulfillmentItemId), [
      'food-2-progress',
      'food-1-progress',
    ]);
    expect(lines.map((item) => item.completed), [false, true]);
    expect(order.hasActionableQuantity('kitchen'), isTrue);
    expect(order.isCompleteAt('kitchen'), isFalse);
  });

  test(
    'combo handoff count uses food components instead of the parent line',
    () {
      final order = EmergencyFulfillmentOrder.fromJson({
        'queue_id': 'queue-combo',
        'order_id': 'order-combo',
        'queue_no': 1,
        'table_number': '104',
        'floor_label': '1F',
        'created_at': '2026-08-16T02:00:00Z',
        'items': [
          {
            'id': 'combo-parent',
            'order_item_id': 'order-item-combo',
            'ordered_quantity': 1,
            'kitchen_done_quantity': 1,
            'tray_received_quantity': 0,
            'tray_dispatched_quantity': 0,
            'floor_served_quantity': 0,
            'combo_components': [
              {
                'menu_item_id': 'food-1',
                'name_vi': 'Tteokbokki Truyền Thống',
                'quantity': 1,
                'fulfillment_route': 'kitchen_tray_floor',
              },
              {
                'menu_item_id': 'food-2',
                'name_vi': 'Kimbap Cá Ngừ',
                'quantity': 1,
                'fulfillment_route': 'kitchen_tray_floor',
              },
              {
                'menu_item_id': 'drink-1',
                'name_vi': 'Nước Suối',
                'quantity': 1,
                'fulfillment_route': 'floor_direct',
              },
            ],
          },
        ],
      });

      expect(order.incomingHandoffQuantityAt('tray'), 2);
    },
  );

  test('completed station timer stops at that station completion', () {
    final order = EmergencyFulfillmentOrder(
      queueId: 'queue-1',
      orderId: 'order-1',
      queueNo: 1,
      tableNumber: '102',
      floorLabel: '1F',
      createdAt: DateTime.utc(2026, 8, 15, 9),
      stationStartedAt: DateTime.utc(2026, 8, 15, 10),
      stationCompletedAt: DateTime.utc(2026, 8, 15, 10, 4, 32),
      items: const [
        EmergencyFulfillmentItem(
          id: 'food-1',
          orderItemId: 'order-item-1',
          nameKo: '김밥',
          nameVi: 'Cơm cuộn',
          nameEn: 'Gimbap',
          orderedQuantity: 1,
          kitchenDoneQuantity: 1,
          trayReceivedQuantity: 1,
          trayDispatchedQuantity: 1,
          floorServedQuantity: 0,
          needsReview: false,
        ),
      ],
    );

    expect(
      order.stationElapsedAt(DateTime.utc(2026, 8, 15, 11), 'tray'),
      const Duration(minutes: 4, seconds: 32),
    );
    expect(
      order.stationElapsedAt(DateTime.utc(2026, 8, 15, 12), 'tray'),
      const Duration(minutes: 4, seconds: 32),
    );
  });

  test('station timer waits at zero until work reaches tray or floor', () {
    final order = EmergencyFulfillmentOrder(
      queueId: 'queue-1',
      orderId: 'order-1',
      queueNo: 1,
      tableNumber: '102',
      floorLabel: '1F',
      createdAt: DateTime.utc(2026, 8, 15, 9),
      items: const [
        EmergencyFulfillmentItem(
          id: 'food-1',
          orderItemId: 'order-item-1',
          nameKo: '김밥',
          nameVi: 'Cơm cuộn',
          nameEn: 'Gimbap',
          orderedQuantity: 1,
          kitchenDoneQuantity: 0,
          trayReceivedQuantity: 0,
          trayDispatchedQuantity: 0,
          floorServedQuantity: 0,
          needsReview: false,
        ),
      ],
    );

    expect(
      order.stationElapsedAt(DateTime.utc(2026, 8, 15, 12), 'tray'),
      Duration.zero,
    );
    expect(
      order.stationElapsedAt(DateTime.utc(2026, 8, 15, 12), 'floor'),
      Duration.zero,
    );
  });

  test('tray and floor identify food received from the previous stage', () {
    const item = EmergencyFulfillmentItem(
      id: 'food-1',
      orderItemId: 'order-item-1',
      nameKo: '떡볶이',
      nameVi: 'Bánh gạo cay',
      nameEn: 'Spicy rice cake',
      orderedQuantity: 2,
      kitchenDoneQuantity: 1,
      trayReceivedQuantity: 1,
      trayDispatchedQuantity: 0,
      floorServedQuantity: 0,
      needsReview: false,
    );

    expect(item.isReadyFromPreviousStageAt('kitchen'), isFalse);
    expect(item.isReadyFromPreviousStageAt('tray'), isTrue);
    expect(item.isReadyFromPreviousStageAt('floor'), isFalse);

    final dispatched = item.withStage('tray_dispatched', 1);
    expect(dispatched.isReadyFromPreviousStageAt('tray'), isFalse);
    expect(dispatched.isReadyFromPreviousStageAt('floor'), isTrue);

    final served = dispatched.withStage('floor_served', 1);
    expect(served.isReadyFromPreviousStageAt('floor'), isFalse);
  });

  test('station menu ordering keeps handoffs first and handled items last', () {
    const ready = EmergencyFulfillmentItem(
      id: 'ready',
      orderItemId: 'ready-order-item',
      nameKo: '준비',
      nameVi: 'Sẵn sàng',
      nameEn: 'Ready',
      orderedQuantity: 2,
      kitchenDoneQuantity: 2,
      trayReceivedQuantity: 2,
      trayDispatchedQuantity: 1,
      floorServedQuantity: 0,
      needsReview: false,
    );
    const inProgress = EmergencyFulfillmentItem(
      id: 'in-progress',
      orderItemId: 'in-progress-order-item',
      nameKo: '진행',
      nameVi: 'Đang làm',
      nameEn: 'In progress',
      orderedQuantity: 2,
      kitchenDoneQuantity: 2,
      trayReceivedQuantity: 2,
      trayDispatchedQuantity: 0,
      floorServedQuantity: 0,
      needsReview: false,
    );
    const handled = EmergencyFulfillmentItem(
      id: 'handled',
      orderItemId: 'handled-order-item',
      nameKo: '완료',
      nameVi: 'Hoàn tất',
      nameEn: 'Handled',
      orderedQuantity: 2,
      kitchenDoneQuantity: 2,
      trayReceivedQuantity: 2,
      trayDispatchedQuantity: 1,
      floorServedQuantity: 1,
      needsReview: false,
    );
    final order = EmergencyFulfillmentOrder(
      queueId: 'queue-sort',
      orderId: 'order-sort',
      queueNo: 1,
      tableNumber: '101',
      floorLabel: '1F',
      createdAt: DateTime.utc(2026, 8, 16),
      items: const [handled, inProgress, ready],
    );

    expect(order.visibleItemsAt('floor').map((item) => item.id), [
      'ready',
      'in-progress',
      'handled',
    ]);
    final displayItems = order.displayItemsAt('floor');
    expect(displayItems.map((item) => item.id), [
      'ready',
      'in-progress',
      'handled',
    ]);
    expect(displayItems.first.readyFromPreviousStage, isTrue);
    expect(displayItems.last.completed, isTrue);
    expect(handled.isCompletedAt('floor'), isFalse);
    expect(handled.isDisplayCompletedAt('floor'), isTrue);

    final kitchenOrder = order.copyWith(
      items: [
        handled.withStage('kitchen_done', handled.orderedQuantity),
        inProgress.withStage('kitchen_done', 0),
      ],
    );
    expect(kitchenOrder.visibleItemsAt('kitchen').map((item) => item.id), [
      'in-progress',
      'handled',
    ]);

    final trayOrder = order.copyWith(
      items: [
        handled
            .withStage('tray_received', handled.kitchenDoneQuantity)
            .withStage('tray_dispatched', handled.kitchenDoneQuantity),
        inProgress.withStage('kitchen_done', 0).withStage('tray_received', 0),
        ready.withStage('tray_dispatched', 0),
      ],
    );
    expect(trayOrder.visibleItemsAt('tray').map((item) => item.id), [
      'ready',
      'in-progress',
      'handled',
    ]);
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

  test(
    'combo component progress migration is durable and independently keyed',
    () {
      final migration = File(
        'supabase/migrations/20260816190000_kds_combo_component_progress.sql',
      ).readAsStringSync();

      expect(migration, contains('emergency_combo_component_items'));
      expect(
        migration,
        contains('UNIQUE (session_id, order_item_id, line_key)'),
      );
      expect(migration, contains('emergency_record_combo_component_progress'));
      expect(migration, contains('combo_component_item_id'));
      expect(migration, contains('emergency_add_combo_component_progress'));
      expect(migration, contains('production-gate: self-verifying'));
    },
  );

  test('additive SQL exposes per-station timer boundaries', () {
    final migration = File(
      'supabase/migrations/20260815172000_emergency_station_timers.sql',
    ).readAsStringSync();

    expect(migration, contains('get_emergency_station_timings'));
    expect(migration, contains("WHEN 'tray' THEN 'kitchen_done'"));
    expect(migration, contains("WHEN 'floor' THEN 'tray_dispatched'"));
    expect(migration, contains("ELSE 'floor_served'"));
    expect(migration, contains('station_started_at'));
    expect(migration, contains('station_completed_at'));
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
    expect(digitalReceiptFooterThanksVi, 'Cảm ơn quý khách!');
    expect(
      digitalReceiptFooterNoticeVi,
      'Biên lai này dùng làm chứng từ thanh toán, '
      'không phải hóa đơn đỏ.',
    );
    final pdfSource = File(
      'lib/core/services/digital_receipt_pdf_service.dart',
    ).readAsStringSync();
    expect(RegExp(r'[\uac00-\ud7af]').hasMatch(pdfSource), isFalse);
  });
}
