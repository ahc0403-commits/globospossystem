import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/customer_delivery_screen.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/tray_floor_transition_sheet.dart';

void main() {
  testWidgets(
    'floor transition stays horizontally split and submits one floor',
    (tester) async {
      final submitted = <TrayFloorTransitionSummary>[];
      await tester.binding.setSurfaceSize(const Size(900, 600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(),
          locale: const Locale('ko'),
          home: TrayFloorTransitionSheet(
            firstFloor: _traySummary('1F', '김밥', 3),
            secondFloor: _traySummary('2F', '김치찌개', 2),
            unsupportedFloorQuantity: 0,
            onSubmit: (summary) async {
              submitted.add(summary);
              return true;
            },
          ),
        ),
      );

      final first = tester.getTopLeft(
        find.byKey(const ValueKey('tray_floor_transition_column_1F')),
      );
      final second = tester.getTopLeft(
        find.byKey(const ValueKey('tray_floor_transition_column_2F')),
      );
      expect(first.dy, second.dy);
      expect(first.dx, lessThan(second.dx));
      expect(find.byIcon(Icons.add_circle_rounded), findsNWidgets(2));
      expect(
        find.byIcon(Icons.remove_circle_outline_rounded),
        findsNWidgets(2),
      );

      final firstGroup = _traySummary('1F', '김밥', 3).groups.single;
      await tester.tap(
        find.byKey(ValueKey('tray_floor_transition_plus_1F_${firstGroup.key}')),
      );
      await tester.tap(
        find.byKey(ValueKey('tray_floor_transition_plus_1F_${firstGroup.key}')),
      );
      await tester.pump();
      expect(
        tester
            .widget<Text>(
              find.byKey(
                ValueKey('tray_floor_transition_progress_1F_${firstGroup.key}'),
              ),
            )
            .data,
        '2/3',
      );

      await tester.tap(
        find.byKey(const ValueKey('tray_floor_transition_confirm_1F')),
      );
      await tester.pumpAndSettle();
      expect(submitted, hasLength(1));
      expect(submitted.single.floorLabel, '1F');
      expect(submitted.single.totalQuantity, 2);
      expect(submitted.single.allocations.single.quantity, 2);
      expect(
        find.byKey(const Key('tray_floor_transition_screen')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('floor transition remains two columns on a narrow display', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    for (final scale in [1.0, 1.3, 2.0]) {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.build(),
          locale: const Locale('ko'),
          builder: (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
          home: TrayFloorTransitionSheet(
            firstFloor: _traySummary('1F', '아주 긴 김밥 메뉴 이름', 123),
            secondFloor: _traySummary('2F', '아주 긴 김치찌개 메뉴 이름', 456),
            unsupportedFloorQuantity: 0,
            onSubmit: (_) async => true,
          ),
        ),
      );
      await tester.pump();

      final first = tester.getTopLeft(
        find.byKey(const ValueKey('tray_floor_transition_column_1F')),
      );
      final second = tester.getTopLeft(
        find.byKey(const ValueKey('tray_floor_transition_column_2F')),
      );
      expect(first.dy, second.dy);
      expect(first.dx, lessThan(second.dx));
      expect(tester.takeException(), isNull, reason: 'text scale $scale');
    }
  });

  testWidgets('customer delivery keeps eight slots and submits selected food', (
    tester,
  ) async {
    final submitted = <CustomerDeliveryAllocation>[];
    final boxes = List.generate(9, (index) => _customerBox(index));
    await tester.binding.setSurfaceSize(const Size(1200, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        locale: const Locale('ko'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: CustomerDeliveryScreen(
          floorLabel: '1F',
          boxes: boxes,
          onSubmit: (allocations) async {
            submitted.addAll(allocations);
            return false;
          },
        ),
      ),
    );

    expect(find.byKey(const Key('customer_delivery_grid_8_slots')), findsOne);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'customer_delivery_box_',
            ),
      ),
      findsNWidgets(8),
    );
    expect(find.byKey(const Key('customer_delivery_complete')), findsOne);

    await tester.tap(find.byKey(const Key('customer_delivery_next_page')));
    await tester.pump();
    expect(find.byKey(const Key('customer_delivery_page')), findsOne);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.key is ValueKey<String> &&
            (widget.key! as ValueKey<String>).value.startsWith(
              'customer_delivery_empty_slot_',
            ),
      ),
      findsNWidgets(7),
    );

    await tester.tap(find.byKey(const Key('customer_delivery_previous_page')));
    await tester.pump();
    final firstMenu = boxes.first.menus.single;
    await tester.tap(
      find.byKey(ValueKey('customer_delivery_plus_${firstMenu.key}')),
    );
    await tester.pump();
    expect(
      tester
          .widget<IconButton>(
            find.byKey(const Key('customer_delivery_next_page')),
          )
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<Text>(
            find.byKey(ValueKey('customer_delivery_progress_${firstMenu.key}')),
          )
          .data,
      '1/2',
    );

    await tester.tap(find.byKey(const Key('customer_delivery_complete')));
    await tester.pump();
    expect(submitted, hasLength(1));
    expect(submitted.single.queueId, boxes.first.queueId);
    expect(submitted.single.quantity, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('customer delivery uses a two by four portrait grid', (
    tester,
  ) async {
    final boxes = List.generate(8, (index) => _customerBox(index));
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.build(),
        locale: const Locale('ko'),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: CustomerDeliveryScreen(
          floorLabel: '1F',
          boxes: boxes,
          onSubmit: (_) async => true,
        ),
      ),
    );

    final first = find.byKey(const ValueKey('customer_delivery_box_queue-0'));
    final second = find.byKey(const ValueKey('customer_delivery_box_queue-1'));
    final third = find.byKey(const ValueKey('customer_delivery_box_queue-2'));
    expect(tester.getTopLeft(first).dy, tester.getTopLeft(second).dy);
    expect(tester.getTopLeft(first).dx, lessThan(tester.getTopLeft(second).dx));
    expect(
      tester.getTopLeft(third).dy,
      greaterThan(tester.getTopLeft(first).dy),
    );
    expect(tester.getTopLeft(third).dx, tester.getTopLeft(first).dx);
    expect(tester.takeException(), isNull);
  });
}

TrayFloorTransitionSummary _traySummary(
  String floor,
  String name,
  int quantity,
) => TrayFloorTransitionSummary(
  floorLabel: floor,
  groups: [
    TrayFloorTransitionMenuGroup(
      key: '$floor-$name',
      nameKo: name,
      nameVi: name,
      nameEn: name,
      quantity: quantity,
    ),
  ],
  allocations: [
    TrayFloorTransitionAllocation(
      menuKey: '$floor-$name',
      itemId: 'item-$floor',
      queueId: 'queue-$floor',
      sourceKind: 'base',
      quantity: quantity,
    ),
  ],
);

CustomerDeliveryBox _customerBox(int index) {
  final allocation = CustomerDeliveryAllocation(
    itemId: 'item-$index',
    queueId: 'queue-$index',
    sourceKind: 'base',
    quantity: 2,
  );
  return CustomerDeliveryBox(
    queueId: 'queue-$index',
    orderId: 'order-$index',
    queueNo: index + 1,
    tableNumber: 'T${index + 1}',
    floorLabel: '1F',
    createdAt: DateTime.utc(2026, 9, 18, 10, index),
    menus: [
      CustomerDeliveryMenu(
        key: 'queue-$index\u0000menu-$index',
        nameKo: '메뉴 $index',
        nameVi: 'Món $index',
        nameEn: 'Menu $index',
        availableQuantity: 2,
        allocations: [allocation],
      ),
    ],
  );
}
