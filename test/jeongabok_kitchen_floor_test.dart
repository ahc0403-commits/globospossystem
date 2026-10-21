import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/kitchen_checket_handoff_sheet.dart';

EmergencyFulfillmentItem item({bool direct = false}) =>
    EmergencyFulfillmentItem.fromJson({
      'id': 'line',
      'order_item_id': 'order-line',
      'name_ko': '국수',
      'name_vi': 'Mì',
      'name_en': 'Noodles',
      'ordered_quantity': 2,
      'workflow_version': 2,
      'kitchen_direct_to_floor': direct,
      'batch_received_at': '2026-10-20T01:00:00Z',
      'kitchen_first_done_at': '2026-10-20T01:01:00Z',
    });

void main() {
  test(
    'direct kitchen completion prepares floor service without a checker',
    () {
      final ready = item(direct: true).withStage('kitchen_done', 1);
      expect(ready.readyUnservedQuantity, 1);
      expect(ready.trayPendingQuantity, 0);
      expect(ready.isActionableAt('floor'), isTrue);
      expect(ready.isActionableAt('tray'), isFalse);
      expect(ready.floorServedQuantity, 0);
      expect(ready.stationStartedAt('floor'), DateTime.utc(2026, 10, 20, 1, 1));
      expect(ready.isRevertibleAt('kitchen'), isTrue);
      final served = ready.withStage('floor_served', 1);
      expect(served.isRevertibleAt('kitchen'), isFalse);
      expect(
        served.withStage('floor_served', 0).isRevertibleAt('kitchen'),
        isTrue,
      );
      final undone = ready.withStage('kitchen_done', 0);
      expect(undone.readyUnservedQuantity, 0);
      expect(undone.kitchenDirectToFloor, isTrue);
    },
  );

  test('default store still waits for checker and keeps its undo boundary', () {
    final ready = item().withStage('kitchen_done', 1);
    expect(ready.readyUnservedQuantity, 0);
    expect(ready.isActionableAt('floor'), isFalse);
    expect(ready.isActionableAt('tray'), isTrue);
    expect(
      ready.withStage('tray_dispatched', 1).isRevertibleAt('kitchen'),
      isFalse,
    );
  });

  test(
    'tray shows ordered quantities while waiting for kitchen completion',
    () {
      final pending = item();
      final order = EmergencyFulfillmentOrder(
        queueId: 'queue',
        orderId: 'order',
        queueNo: 1,
        tableNumber: '2107',
        floorLabel: '2F',
        createdAt: DateTime(2026),
        items: [pending],
      );
      final display = order.displayItemsAt('tray').single;
      expect(display.completedQuantity, 0);
      expect(display.totalQuantity, 2);
      expect(pending.isActionableAt('tray'), isFalse);
      expect(
        pending.withStage('kitchen_done', 1).isActionableAt('tray'),
        isTrue,
      );
      expect(pending.withStage('kitchen_done', 1).readyUnservedQuantity, 0);
    },
  );

  test('store workflow survives state updates including an empty board', () {
    final state = EmergencyFulfillmentState.fromJson({
      'assigned': true,
      'active': true,
      'station_type': 'kitchen',
      'kitchen_direct_to_floor': true,
      'orders': <Object>[],
    });
    expect(state.copyWith(isLoading: true).kitchenDirectToFloor, isTrue);
    expect(const EmergencyFulfillmentState().kitchenDirectToFloor, isFalse);
  });

  for (final direct in [false, true]) {
    testWidgets('handoff sheet labels match the store workflow: $direct', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          home: KitchenChecketHandoffSheet(
            directToFloor: direct,
            groups: const [],
            onSubmit: (_) async => true,
          ),
        ),
      );
      expect(
        find.text(direct ? 'Floor handoff' : 'Checker handoff'),
        findsOneWidget,
      );
      expect(
        find.text(direct ? 'Checker handoff' : 'Floor handoff'),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
