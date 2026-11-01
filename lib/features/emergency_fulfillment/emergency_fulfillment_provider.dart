import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/i18n/menu_localization.dart';
import '../../core/models/fulfillment_mode.dart';
import '../../core/services/emergency_web_bridge.dart';
import '../../core/utils/live_sync_scope.dart';
import '../../core/utils/time_utils.dart';
import '../../core/services/pos_backend.dart';
import 'kds_realtime_sync.dart';
import 'kds_progress_journal.dart';
import '../../core/utils/deadline_http_client.dart';

const emergencyHandoffAlarmCoalesceDelay = Duration(seconds: 2);
const emergencyFloorDirectBeverageAlarmCoalesceDelay = Duration(seconds: 2);
const emergencyAdditionalOrderAlarmCoalesceDelay = Duration(seconds: 2);
const bunsikKdsStoreId = '8bc9eef5-dcd5-46b1-b931-23f77132322c';

class KdsCompletedHistoryStatus {
  const KdsCompletedHistoryStatus({
    this.loading = false,
    this.page = 0,
    this.hasMore = false,
    this.error,
  });

  final bool loading;
  final int page;
  final bool hasMore;
  final String? error;
}

Duration emergencySnapshotRetryDelay(int consecutiveFailures) =>
    switch (consecutiveFailures) {
      <= 1 => const Duration(seconds: 5),
      2 => const Duration(seconds: 15),
      _ => const Duration(seconds: 30),
    };

String formatEmergencyElapsed(Duration elapsed) {
  final totalSeconds = elapsed.inSeconds < 0 ? 0 : elapsed.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
}

DateTime? _optionalDateTime(Object? value) {
  final raw = value?.toString();
  return raw == null || raw.isEmpty ? null : DateTime.tryParse(raw);
}

/// Keeps the last known station clock boundaries while the fast order
/// snapshot is published ahead of the timing RPC.
EmergencyFulfillmentState preserveEmergencyStationTimings(
  EmergencyFulfillmentState current,
  EmergencyFulfillmentState previous,
) {
  if (current.sessionId == null ||
      current.sessionId != previous.sessionId ||
      current.stationType != previous.stationType) {
    return current;
  }

  final previousOrdersByQueueId = <String, EmergencyFulfillmentOrder>{
    // Live rows win over an older, independently loaded history page.
    for (final order in [...previous.completedOrders, ...previous.orders])
      order.queueId: order,
  };
  EmergencyFulfillmentOrder preserve(EmergencyFulfillmentOrder order) {
    final cached = previousOrdersByQueueId[order.queueId];
    if (cached == null) return order;
    return order.copyWith(
      stationStartedAt: order.stationStartedAt ?? cached.stationStartedAt,
      stationCompletedAt: order.stationCompletedAt ?? cached.stationCompletedAt,
    );
  }

  return current.copyWith(
    orders: current.orders.map(preserve).toList(growable: false),
    completedOrders: current.completedOrders
        .map(preserve)
        .toList(growable: false),
  );
}

void _mergeStationTimings(Map<String, dynamic> snapshot, dynamic rawTimings) {
  if (rawTimings is! List) return;
  final timingsByQueue = <String, Map<String, dynamic>>{
    for (final timing in rawTimings.whereType<Map>())
      if (timing['queue_id'] != null)
        timing['queue_id'].toString(): Map<String, dynamic>.from(timing),
  };
  for (final key in ['orders', 'completed_orders']) {
    final rawOrders = snapshot[key];
    if (rawOrders is! List) continue;
    snapshot[key] = rawOrders
        .map((rawOrder) {
          if (rawOrder is! Map) return rawOrder;
          final order = Map<String, dynamic>.from(rawOrder);
          final timing = timingsByQueue[order['queue_id']?.toString()];
          if (timing != null) {
            order['station_started_at'] = timing['station_started_at'];
            order['station_completed_at'] = timing['station_completed_at'];
          }
          return order;
        })
        .toList(growable: false);
  }
}

class EmergencyComboComponent {
  const EmergencyComboComponent({
    required this.menuItemId,
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.quantity,
    required this.isTotalQuantity,
    required this.fulfillmentRoute,
  });

  final String menuItemId;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final int quantity;
  final bool isTotalQuantity;
  final String fulfillmentRoute;

  bool get isFloorDirect => fulfillmentRoute == 'floor_direct';
  String get paperlessName => nameVi.trim().isEmpty ? 'Món' : nameVi;

  int displayQuantity(int parentQuantity) =>
      isTotalQuantity ? quantity : quantity * parentQuantity;

  String localizedName(String languageCode) => localizedMenuName({
    'name': _firstEmergencyMenuName(nameKo, nameVi, nameEn),
    'name_ko': nameKo,
    'name_vi': nameVi,
    'name_en': nameEn,
  }, languageCode);

  factory EmergencyComboComponent.fromJson(Map<String, dynamic> json) =>
      EmergencyComboComponent(
        menuItemId: json['menu_item_id']?.toString() ?? '',
        nameKo: json['name_ko']?.toString() ?? '',
        nameVi: json['name_vi']?.toString() ?? '',
        nameEn: json['name_en']?.toString() ?? '',
        quantity: _asInt(json['quantity']),
        isTotalQuantity: json['is_total_quantity'] == true,
        fulfillmentRoute:
            json['fulfillment_route']?.toString() ?? 'kitchen_tray_floor',
      );
}

class EmergencyFulfillmentDisplayItem {
  const EmergencyFulfillmentDisplayItem({
    required this.id,
    required this.fulfillmentItemId,
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.quantity,
    required this.completed,
    required this.readyFromPreviousStage,
    required this.readOnly,
    this.completedQuantity,
    this.totalQuantity,
    this.isTakeout = false,
    this.notes,
    this.batchReceivedAt,
    this.stationStartedAt,
    this.stationCompletedAt,
  });

  final String id;
  final String fulfillmentItemId;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final int quantity;
  final bool completed;
  final bool readyFromPreviousStage;
  final bool readOnly;
  final int? completedQuantity;
  final int? totalQuantity;
  final bool isTakeout;
  final String? notes;
  final DateTime? batchReceivedAt;
  final DateTime? stationStartedAt;
  final DateTime? stationCompletedAt;

  String get paperlessName => nameVi.trim().isEmpty ? 'Món' : nameVi;

  String localizedName(String languageCode) => localizedMenuName({
    'name': _firstEmergencyMenuName(nameKo, nameVi, nameEn),
    'name_ko': nameKo,
    'name_vi': nameVi,
    'name_en': nameEn,
  }, languageCode);
}

class EmergencyFulfillmentItem {
  const EmergencyFulfillmentItem({
    required this.id,
    required this.orderItemId,
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.orderedQuantity,
    required this.kitchenDoneQuantity,
    required this.trayReceivedQuantity,
    required this.trayDispatchedQuantity,
    required this.floorServedQuantity,
    required this.needsReview,
    this.kitchenStartedQuantity = 0,
    this.excusedQuantity = 0,
    this.workflowVersion = 1,
    this.kitchenDirectToFloor = false,
    this.menuOptionKey = '',
    this.oldestReadySequence,
    this.oldestTrayReadySequence,
    this.fulfillmentRoute = 'kitchen_tray_floor',
    this.lineKey = 'base',
    this.sourceKind = 'order_item',
    this.comboComponents = const [],
    this.isTakeout = false,
    this.notes,
    this.batchReceivedAt,
    this.kitchenFirstDoneAt,
    this.kitchenLastDoneAt,
    this.trayFirstDispatchedAt,
    this.trayLastDispatchedAt,
    this.floorFirstServedAt,
    this.floorLastServedAt,
  });

  final String id;
  final String orderItemId;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final int orderedQuantity;
  final int kitchenStartedQuantity;
  final int kitchenDoneQuantity;
  final int trayReceivedQuantity;
  final int trayDispatchedQuantity;
  final int floorServedQuantity;
  final int excusedQuantity;
  final bool needsReview;
  final int workflowVersion;
  final bool kitchenDirectToFloor;
  final String menuOptionKey;
  final int? oldestReadySequence;
  final int? oldestTrayReadySequence;
  final String fulfillmentRoute;
  final String lineKey;
  final String sourceKind;
  final List<EmergencyComboComponent> comboComponents;
  final bool isTakeout;
  final String? notes;
  final DateTime? batchReceivedAt;
  final DateTime? kitchenFirstDoneAt;
  final DateTime? kitchenLastDoneAt;
  final DateTime? trayFirstDispatchedAt;
  final DateTime? trayLastDispatchedAt;
  final DateTime? floorFirstServedAt;
  final DateTime? floorLastServedAt;

  bool get isFloorDirect => fulfillmentRoute == 'floor_direct';
  bool get usesKitchenHandoffWorkflow => workflowVersion >= 2 && !isFloorDirect;
  int get requiredQuantity =>
      (orderedQuantity - excusedQuantity).clamp(0, orderedQuantity);
  int get readyUnservedQuantity =>
      (trayDispatchedQuantity - floorServedQuantity).clamp(0, requiredQuantity);
  int get trayPendingQuantity =>
      (kitchenDoneQuantity - trayDispatchedQuantity).clamp(0, requiredQuantity);
  String get paperlessName => nameVi.trim().isEmpty ? 'Món' : nameVi;

  DateTime? stationStartedAt(String stationType) => switch (stationType) {
    'kitchen' => batchReceivedAt,
    'tray' => kitchenFirstDoneAt,
    'floor' =>
      isFloorDirect
          ? batchReceivedAt
          : (kitchenDirectToFloor ? kitchenFirstDoneAt : trayFirstDispatchedAt),
    _ => null,
  };

  DateTime? stationCompletedAt(String stationType) => switch (stationType) {
    'kitchen' => kitchenLastDoneAt,
    'tray' => trayLastDispatchedAt,
    'floor' => floorLastServedAt,
    _ => null,
  };

  bool isActionableAt(String stationType) => switch (stationType) {
    'kitchen' => !isFloorDirect && kitchenDoneQuantity < requiredQuantity,
    'tray' =>
      !isFloorDirect &&
          (trayReceivedQuantity < kitchenDoneQuantity ||
              trayDispatchedQuantity < kitchenDoneQuantity),
    'floor' =>
      floorServedQuantity <
          (isFloorDirect ? requiredQuantity : trayDispatchedQuantity),
    _ => false,
  };

  bool isRevertibleAt(String stationType) => switch (stationType) {
    'kitchen' =>
      !isFloorDirect &&
          kitchenDoneQuantity >
              (kitchenDirectToFloor
                  ? floorServedQuantity
                  : trayReceivedQuantity),
    'tray' =>
      !isFloorDirect &&
          trayDispatchedQuantity > floorServedQuantity &&
          trayReceivedQuantity > 0,
    'floor' => floorServedQuantity > 0,
    _ => false,
  };

  bool isCompletedAt(String stationType) => switch (stationType) {
    'kitchen' => !isFloorDirect && kitchenDoneQuantity >= requiredQuantity,
    'tray' =>
      !isFloorDirect &&
          trayReceivedQuantity >= requiredQuantity &&
          trayDispatchedQuantity >= requiredQuantity,
    'floor' => floorServedQuantity >= requiredQuantity,
    _ => false,
  };

  bool isDisplayCompletedAt(String stationType) => switch (stationType) {
    'kitchen' => !isFloorDirect && kitchenDoneQuantity >= requiredQuantity,
    'tray' =>
      !isFloorDirect &&
          kitchenDoneQuantity > 0 &&
          trayReceivedQuantity >= kitchenDoneQuantity &&
          trayDispatchedQuantity >= kitchenDoneQuantity,
    'floor' => switch (isFloorDirect
        ? requiredQuantity
        : trayDispatchedQuantity) {
      final limit when limit > 0 => floorServedQuantity >= limit,
      _ => false,
    },
    _ => false,
  };

  bool isReadyFromPreviousStageAt(String stationType) => switch (stationType) {
    'tray' => !isFloorDirect && kitchenDoneQuantity > trayDispatchedQuantity,
    'floor' =>
      (isFloorDirect ? requiredQuantity : trayDispatchedQuantity) >
          floorServedQuantity,
    _ => false,
  };

  int displayPriorityAt(String stationType) {
    if (isReadyFromPreviousStageAt(stationType)) return 0;
    if (isDisplayCompletedAt(stationType)) return 2;
    return 1;
  }

  String localizedName(String languageCode) => localizedMenuName({
    'name': _firstEmergencyMenuName(nameKo, nameVi, nameEn),
    'name_ko': nameKo,
    'name_vi': nameVi,
    'name_en': nameEn,
  }, languageCode);

  int quantityForStage(String stage) => switch (stage) {
    'kitchen_started' => kitchenStartedQuantity,
    'kitchen_done' => kitchenDoneQuantity,
    'tray_ready' => kitchenDoneQuantity,
    'tray_received' => trayReceivedQuantity,
    'tray_dispatched' => trayDispatchedQuantity,
    'floor_served' => floorServedQuantity,
    _ => 0,
  };

  int incomingHandoffQuantityAt(String stationType) {
    final parentQuantity = switch (stationType) {
      'tray' => kitchenDoneQuantity,
      'floor' => trayDispatchedQuantity,
      _ => 0,
    };
    if (parentQuantity <= 0) return 0;
    if (comboComponents.isEmpty) return parentQuantity;

    return comboComponents.where((component) => !component.isFloorDirect).fold(
      0,
      (total, component) {
        final componentQuantity = component.isTotalQuantity
            ? orderedQuantity > 0
                  ? (component.quantity * parentQuantity / orderedQuantity)
                        .ceil()
                  : 0
            : component.quantity * parentQuantity;
        return total + componentQuantity;
      },
    );
  }

  EmergencyFulfillmentItem withStage(
    String stage,
    int quantity, {
    bool preserveKitchenStarted = false,
    bool updateOldestReadySequence = false,
    int? oldestReadySequence,
    bool updateOldestTrayReadySequence = false,
    int? oldestTrayReadySequence,
  }) => EmergencyFulfillmentItem(
    id: id,
    orderItemId: orderItemId,
    nameKo: nameKo,
    nameVi: nameVi,
    nameEn: nameEn,
    orderedQuantity: orderedQuantity,
    kitchenStartedQuantity:
        stage == 'kitchen_started' ||
            (stage == 'kitchen_done' && usesKitchenHandoffWorkflow)
        ? stage == 'kitchen_done' &&
                  (kitchenDirectToFloor || preserveKitchenStarted)
              ? math.max(kitchenStartedQuantity, quantity)
              : quantity
        : kitchenStartedQuantity,
    kitchenDoneQuantity: stage == 'kitchen_done' || stage == 'tray_ready'
        ? quantity
        : kitchenDoneQuantity,
    trayReceivedQuantity:
        stage == 'tray_received' ||
            stage == 'tray_ready' ||
            (stage == 'tray_dispatched' && usesKitchenHandoffWorkflow) ||
            (stage == 'kitchen_done' && kitchenDirectToFloor)
        ? quantity
        : trayReceivedQuantity,
    trayDispatchedQuantity:
        stage == 'tray_dispatched' ||
            stage == 'tray_ready' ||
            (stage == 'kitchen_done' && kitchenDirectToFloor)
        ? quantity
        : trayDispatchedQuantity,
    floorServedQuantity: stage == 'floor_served'
        ? quantity
        : floorServedQuantity,
    excusedQuantity: excusedQuantity,
    needsReview: needsReview,
    workflowVersion: workflowVersion,
    kitchenDirectToFloor: kitchenDirectToFloor,
    menuOptionKey: menuOptionKey,
    oldestReadySequence: updateOldestReadySequence
        ? oldestReadySequence
        : this.oldestReadySequence,
    oldestTrayReadySequence: updateOldestTrayReadySequence
        ? oldestTrayReadySequence
        : this.oldestTrayReadySequence,
    fulfillmentRoute: fulfillmentRoute,
    lineKey: lineKey,
    sourceKind: sourceKind,
    comboComponents: comboComponents,
    isTakeout: isTakeout,
    batchReceivedAt: batchReceivedAt,
    kitchenFirstDoneAt: kitchenFirstDoneAt,
    kitchenLastDoneAt: kitchenLastDoneAt,
    trayFirstDispatchedAt: trayFirstDispatchedAt,
    trayLastDispatchedAt: trayLastDispatchedAt,
    floorFirstServedAt: floorFirstServedAt,
    floorLastServedAt: floorLastServedAt,
  );

  factory EmergencyFulfillmentItem.fromJson(Map<String, dynamic> json) {
    final rawComponents = json['combo_components'];
    return EmergencyFulfillmentItem(
      menuOptionKey: json['menu_option_snapshot'] is Map
          ? (json['menu_option_snapshot'] as Map)['choice_signature']
                    ?.toString() ??
                jsonEncode([
                  for (final key in [
                    'portion_code',
                    'spice_level',
                    'spice_choice',
                  ])
                    (json['menu_option_snapshot'] as Map)[key],
                ])
          : '',
      id: json['id']?.toString() ?? '',
      orderItemId: json['order_item_id']?.toString() ?? '',
      nameKo: json['name_ko']?.toString() ?? '',
      nameVi: json['name_vi']?.toString() ?? '',
      nameEn: json['name_en']?.toString() ?? '',
      orderedQuantity: _asInt(json['ordered_quantity']),
      kitchenStartedQuantity: json.containsKey('kitchen_started_quantity')
          ? _asInt(json['kitchen_started_quantity'])
          : _asInt(json['kitchen_done_quantity']),
      kitchenDoneQuantity: _asInt(json['kitchen_done_quantity']),
      trayReceivedQuantity: _asInt(json['tray_received_quantity']),
      trayDispatchedQuantity: _asInt(json['tray_dispatched_quantity']),
      floorServedQuantity: _asInt(json['floor_served_quantity']),
      excusedQuantity: _asInt(json['excused_quantity']),
      needsReview: json['needs_review'] == true,
      workflowVersion: _asInt(json['workflow_version']).clamp(1, 2),
      kitchenDirectToFloor: json['kitchen_direct_to_floor'] == true,
      oldestReadySequence: json['oldest_ready_sequence'] == null
          ? null
          : _asInt(json['oldest_ready_sequence']),
      oldestTrayReadySequence: json['oldest_tray_ready_sequence'] == null
          ? null
          : _asInt(json['oldest_tray_ready_sequence']),
      fulfillmentRoute:
          json['fulfillment_route']?.toString() ?? 'kitchen_tray_floor',
      lineKey: json['line_key']?.toString() ?? 'base',
      sourceKind: json['source_kind']?.toString() ?? 'order_item',
      isTakeout: json['is_takeout'] == true,
      notes: json['notes']?.toString(),
      batchReceivedAt: _optionalDateTime(json['batch_received_at']),
      kitchenFirstDoneAt: _optionalDateTime(json['kitchen_first_done_at']),
      kitchenLastDoneAt: _optionalDateTime(json['kitchen_last_done_at']),
      trayFirstDispatchedAt: _optionalDateTime(
        json['tray_first_dispatched_at'],
      ),
      trayLastDispatchedAt: _optionalDateTime(json['tray_last_dispatched_at']),
      floorFirstServedAt: _optionalDateTime(json['floor_first_served_at']),
      floorLastServedAt: _optionalDateTime(json['floor_last_served_at']),
      comboComponents: rawComponents is List
          ? rawComponents
                .whereType<Map>()
                .map(
                  (component) => EmergencyComboComponent.fromJson(
                    Map<String, dynamic>.from(component),
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }
}

class EmergencyOrderBatchTiming {
  const EmergencyOrderBatchTiming({
    required this.sequence,
    required this.receivedAt,
    required this.isSupplemental,
    required this.items,
  });

  final int sequence;
  final DateTime receivedAt;
  final bool isSupplemental;
  final List<EmergencyFulfillmentDisplayItem> items;

  bool get completed =>
      items.isNotEmpty && items.every((item) => item.completed);

  DateTime? get startedAt {
    final values = items
        .map((item) => item.stationStartedAt)
        .whereType<DateTime>();
    if (values.isEmpty) return null;
    return values.reduce((left, right) => left.isBefore(right) ? left : right);
  }

  DateTime? get completedAt {
    if (!completed) return null;
    final values = items
        .map((item) => item.stationCompletedAt)
        .whereType<DateTime>()
        .toList(growable: false);
    if (values.length != items.length) return null;
    return values.reduce((left, right) => left.isAfter(right) ? left : right);
  }

  Duration elapsedAt(DateTime now) {
    final start = startedAt;
    if (start == null) return Duration.zero;
    final elapsed = (completedAt ?? now).difference(start);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }
}

class EmergencyFulfillmentOrder {
  const EmergencyFulfillmentOrder({
    required this.queueId,
    required this.orderId,
    required this.queueNo,
    required this.tableNumber,
    required this.floorLabel,
    required this.createdAt,
    required this.items,
    this.salesChannel = 'dine_in',
    this.directFulfillmentType,
    this.directOrderPacking,
    this.lastActionId,
    this.lastActionAt,
    this.stationStartedAt,
    this.stationCompletedAt,
    this.workflowVersion = 1,
    this.oldestReadySequence,
    this.oldestTrayReadySequence,
  });

  final String queueId;
  final String orderId;
  final int queueNo;
  final String tableNumber;
  final String floorLabel;
  final DateTime createdAt;
  final List<EmergencyFulfillmentItem> items;
  final String salesChannel;
  final String? directFulfillmentType;
  final Map<String, dynamic>? directOrderPacking;
  final String? lastActionId;
  final DateTime? lastActionAt;
  final DateTime? stationStartedAt;
  final DateTime? stationCompletedAt;
  final int workflowVersion;
  final int? oldestReadySequence;
  final int? oldestTrayReadySequence;

  bool get isDelivery => salesChannel == 'delivery';
  bool get isDirectPickup => directFulfillmentType == 'pickup';
  bool get usesKitchenHandoffWorkflow => workflowVersion >= 2 && !isDelivery;
  bool get hasReadyUnservedFood => _operationalItems().any(
    (item) => !item.isFloorDirect && item.readyUnservedQuantity > 0,
  );

  List<EmergencyFulfillmentItem> _operationalItems() {
    final componentBackedOrderItemIds = items
        .where((item) => item.sourceKind == 'combo_component')
        .map((item) => item.orderItemId)
        .toSet();
    return items
        .where(
          (item) =>
              item.sourceKind == 'combo_component' ||
              !componentBackedOrderItemIds.contains(item.orderItemId),
        )
        .toList(growable: false);
  }

  bool hasActionableQuantity(String stationType) =>
      _operationalItems().any((item) => item.isActionableAt(stationType));

  List<EmergencyFulfillmentItem> kitchenPendingItems() => _operationalItems()
      .where(
        (item) =>
            !item.isFloorDirect &&
            !item.needsReview &&
            item.kitchenDoneQuantity < item.requiredQuantity,
      )
      .toList(growable: false);

  List<EmergencyFulfillmentItem> trayFloorPendingItems() {
    if (!usesKitchenHandoffWorkflow || isDelivery) return const [];
    return _operationalItems()
        .where(
          (item) =>
              !item.isFloorDirect &&
              !item.needsReview &&
              item.trayPendingQuantity > 0,
        )
        .toList(growable: false);
  }

  List<EmergencyFulfillmentItem> customerDeliveryPendingItems() {
    if (!usesKitchenHandoffWorkflow || isDelivery) return const [];
    return _operationalItems()
        .where(
          (item) =>
              !item.isFloorDirect &&
              !item.needsReview &&
              item.readyUnservedQuantity > 0,
        )
        .toList(growable: false);
  }

  int incomingHandoffQuantityAt(String stationType) => _operationalItems()
      .where((item) => !item.isFloorDirect)
      .fold(
        0,
        (total, item) => total + item.incomingHandoffQuantityAt(stationType),
      );

  List<EmergencyFulfillmentItem> visibleItemsAt(String stationType) {
    final operationalItems = _operationalItems();
    final visible = stationType == 'floor'
        ? operationalItems
        : operationalItems.where((item) => !item.isFloorDirect);
    final indexed = visible.indexed.toList(growable: false)
      ..sort((left, right) {
        final priority = left.$2
            .displayPriorityAt(stationType)
            .compareTo(right.$2.displayPriorityAt(stationType));
        return priority != 0 ? priority : left.$1.compareTo(right.$1);
      });
    return indexed.map((entry) => entry.$2).toList(growable: false);
  }

  bool isCompleteAt(String stationType) {
    final operationalItems = _operationalItems();
    final relevant = stationType == 'floor'
        ? operationalItems
        : operationalItems
              .where((item) => !item.isFloorDirect)
              .toList(growable: false);
    return relevant.isNotEmpty &&
        relevant.every((item) => item.isCompletedAt(stationType));
  }

  bool isRecentlyCompleteAt(String stationType) =>
      isCompleteAt(stationType) ||
      (!usesKitchenHandoffWorkflow &&
          lastActionId != null &&
          !hasActionableQuantity(stationType));

  DateTime? stationClockStartedAt(String stationType) {
    // Every station shows the customer's total wait from the original order
    // receipt. Handoffs must not reset the visible tray or floor clock.
    if (stationType == 'kitchen' ||
        stationType == 'tray' ||
        stationType == 'floor') {
      return createdAt;
    }
    return null;
  }

  DateTime? stationClockCompletedAt(String stationType) {
    if (!isRecentlyCompleteAt(stationType)) return null;
    if (stationCompletedAt != null) return stationCompletedAt;

    final relevant = displayItemsAt(stationType);
    final values = relevant
        .map((item) => item.stationCompletedAt)
        .whereType<DateTime>()
        .toList(growable: false);
    if (relevant.isNotEmpty && values.length == relevant.length) {
      return values.reduce((left, right) => left.isAfter(right) ? left : right);
    }
    return lastActionAt;
  }

  Duration stationElapsedAt(DateTime now, String stationType) {
    final startedAt = stationClockStartedAt(stationType);
    if (startedAt == null) return Duration.zero;
    final elapsed = (stationClockCompletedAt(stationType) ?? now).difference(
      startedAt,
    );
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  List<EmergencyFulfillmentDisplayItem> displayItemsAt(String stationType) {
    String componentKey(String orderItemId, String lineKey) =>
        '$orderItemId\u0000$lineKey';

    (int, int) progressAt(EmergencyFulfillmentItem item) =>
        switch (stationType) {
          'kitchen' => (item.kitchenDoneQuantity, item.requiredQuantity),
          'tray' => (item.trayDispatchedQuantity, item.requiredQuantity),
          // Order progress includes food still in the kitchen. Readiness and
          // action limits remain based on the quantity actually handed off.
          'floor' => (item.floorServedQuantity, item.requiredQuantity),
          _ => (0, item.requiredQuantity),
        };

    final componentsByParentAndLine = <String, EmergencyFulfillmentItem>{
      for (final item in items)
        if (item.sourceKind == 'combo_component')
          componentKey(item.orderItemId, item.lineKey): item,
    };
    final referencedComponentIds = <String>{};
    for (final item in items) {
      for (final component in item.comboComponents) {
        if (component.menuItemId.isEmpty) continue;
        final componentItem =
            componentsByParentAndLine[componentKey(
              item.orderItemId,
              'combo:${component.menuItemId}',
            )];
        if (componentItem != null) referencedComponentIds.add(componentItem.id);
      }
    }

    final result = <EmergencyFulfillmentDisplayItem>[];
    for (final item in items) {
      if (referencedComponentIds.contains(item.id)) continue;
      if (item.isFloorDirect && stationType != 'floor') continue;
      if (item.comboComponents.isEmpty) {
        final progress = progressAt(item);
        result.add(
          EmergencyFulfillmentDisplayItem(
            id: item.id,
            fulfillmentItemId: item.id,
            nameKo: item.nameKo,
            nameVi: item.nameVi,
            nameEn: item.nameEn,
            quantity: item.requiredQuantity,
            completed: item.isDisplayCompletedAt(stationType),
            readyFromPreviousStage: item.isReadyFromPreviousStageAt(
              stationType,
            ),
            readOnly: false,
            completedQuantity: progress.$1,
            totalQuantity: progress.$2,
            isTakeout: item.isTakeout,
            notes: item.notes,
            batchReceivedAt: item.batchReceivedAt,
            stationStartedAt: item.stationStartedAt(stationType),
            stationCompletedAt: item.stationCompletedAt(stationType),
          ),
        );
        continue;
      }

      for (var index = 0; index < item.comboComponents.length; index += 1) {
        final component = item.comboComponents[index];
        if (component.isFloorDirect && stationType != 'floor') continue;
        final componentItem = component.menuItemId.isEmpty
            ? null
            : componentsByParentAndLine[componentKey(
                item.orderItemId,
                'combo:${component.menuItemId}',
              )];
        final statusItem = componentItem ?? item;
        final progress = progressAt(statusItem);
        result.add(
          EmergencyFulfillmentDisplayItem(
            id: '${item.id}:combo:${component.menuItemId.isEmpty ? index : component.menuItemId}',
            fulfillmentItemId: statusItem.id,
            nameKo: component.nameKo,
            nameVi: component.nameVi,
            nameEn: component.nameEn,
            quantity: component.displayQuantity(item.requiredQuantity),
            completed: statusItem.isDisplayCompletedAt(stationType),
            readyFromPreviousStage: statusItem.isReadyFromPreviousStageAt(
              stationType,
            ),
            readOnly: componentItem == null,
            completedQuantity: progress.$1,
            totalQuantity: progress.$2,
            isTakeout: item.isTakeout,
            notes: item.notes,
            batchReceivedAt: statusItem.batchReceivedAt ?? item.batchReceivedAt,
            stationStartedAt: statusItem.stationStartedAt(stationType),
            stationCompletedAt: statusItem.stationCompletedAt(stationType),
          ),
        );
      }
    }
    final indexed = result.indexed.toList(growable: false)
      ..sort((left, right) {
        int priority(EmergencyFulfillmentDisplayItem item) {
          if (item.readyFromPreviousStage) return 0;
          if (item.completed) return 2;
          return 1;
        }

        final statusOrder = priority(left.$2).compareTo(priority(right.$2));
        return statusOrder != 0 ? statusOrder : left.$1.compareTo(right.$1);
      });
    return indexed.map((entry) => entry.$2).toList(growable: false);
  }

  List<EmergencyOrderBatchTiming> stationBatchesAt(String stationType) {
    final grouped = <int, List<EmergencyFulfillmentDisplayItem>>{};
    final receivedAtByKey = <int, DateTime>{};
    for (final item in displayItemsAt(stationType)) {
      final receivedAt = (item.batchReceivedAt ?? createdAt).toUtc();
      final key = receivedAt.microsecondsSinceEpoch;
      grouped.putIfAbsent(key, () => []).add(item);
      receivedAtByKey[key] = receivedAt;
    }
    final keys = grouped.keys.toList(growable: false)..sort();
    if (keys.isEmpty) return const [];
    final firstReceivedAt = receivedAtByKey[keys.first]!;
    return keys.indexed
        .map((entry) {
          final receivedAt = receivedAtByKey[entry.$2]!;
          return EmergencyOrderBatchTiming(
            sequence: entry.$1 + 1,
            receivedAt: receivedAt,
            isSupplemental:
                receivedAt.difference(firstReceivedAt) >
                const Duration(seconds: 10),
            items: List.unmodifiable(grouped[entry.$2]!),
          );
        })
        .toList(growable: false);
  }

  EmergencyFulfillmentOrder copyWith({
    List<EmergencyFulfillmentItem>? items,
    String? salesChannel,
    String? directFulfillmentType,
    String? lastActionId,
    DateTime? lastActionAt,
    DateTime? stationStartedAt,
    DateTime? stationCompletedAt,
    bool clearLastAction = false,
    bool clearStationCompletedAt = false,
    int? workflowVersion,
    int? oldestReadySequence,
    bool clearOldestReadySequence = false,
    int? oldestTrayReadySequence,
    bool clearOldestTrayReadySequence = false,
  }) => EmergencyFulfillmentOrder(
    queueId: queueId,
    orderId: orderId,
    queueNo: queueNo,
    tableNumber: tableNumber,
    floorLabel: floorLabel,
    createdAt: createdAt,
    items: items ?? this.items,
    salesChannel: salesChannel ?? this.salesChannel,
    directFulfillmentType: directFulfillmentType ?? this.directFulfillmentType,
    directOrderPacking: directOrderPacking,
    lastActionId: clearLastAction ? null : (lastActionId ?? this.lastActionId),
    lastActionAt: clearLastAction ? null : (lastActionAt ?? this.lastActionAt),
    stationStartedAt: stationStartedAt ?? this.stationStartedAt,
    stationCompletedAt: clearLastAction || clearStationCompletedAt
        ? null
        : (stationCompletedAt ?? this.stationCompletedAt),
    workflowVersion: workflowVersion ?? this.workflowVersion,
    oldestReadySequence: clearOldestReadySequence
        ? null
        : (oldestReadySequence ?? this.oldestReadySequence),
    oldestTrayReadySequence: clearOldestTrayReadySequence
        ? null
        : (oldestTrayReadySequence ?? this.oldestTrayReadySequence),
  );

  bool isCompleteForStage(String stage) {
    final operationalItems = _operationalItems();
    return operationalItems.isNotEmpty &&
        operationalItems.every(
          (item) => stage == 'floor_served'
              ? item.floorServedQuantity >= item.requiredQuantity
              : stage == 'kitchen_started'
              ? item.isFloorDirect ||
                    item.kitchenStartedQuantity >= item.requiredQuantity
              : stage == 'tray_ready'
              ? item.isFloorDirect ||
                    item.kitchenDoneQuantity >= item.requiredQuantity
              : item.isFloorDirect ||
                    item.quantityForStage(stage) >= item.requiredQuantity,
        );
  }

  factory EmergencyFulfillmentOrder.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return EmergencyFulfillmentOrder(
      queueId: json['queue_id']?.toString() ?? '',
      orderId: json['order_id']?.toString() ?? '',
      queueNo: _asInt(json['queue_no']),
      tableNumber: json['table_number']?.toString() ?? '-',
      floorLabel: json['floor_label']?.toString() ?? '1F',
      salesChannel: json['sales_channel']?.toString() ?? 'dine_in',
      directFulfillmentType: json['direct_fulfillment_type']?.toString(),
      directOrderPacking: json['direct_order_packing'] is Map
          ? Map<String, dynamic>.from(json['direct_order_packing'] as Map)
          : null,
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now().toUtc(),
      lastActionId: json['last_action_id']?.toString(),
      lastActionAt: DateTime.tryParse(json['last_action_at']?.toString() ?? ''),
      stationStartedAt: DateTime.tryParse(
        json['station_started_at']?.toString() ?? '',
      ),
      stationCompletedAt: DateTime.tryParse(
        json['station_completed_at']?.toString() ?? '',
      ),
      workflowVersion: _asInt(json['workflow_version']).clamp(1, 2),
      oldestReadySequence: json['oldest_ready_sequence'] == null
          ? null
          : _asInt(json['oldest_ready_sequence']),
      oldestTrayReadySequence: json['oldest_tray_ready_sequence'] == null
          ? null
          : _asInt(json['oldest_tray_ready_sequence']),
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) => EmergencyFulfillmentItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }
}

int compareEmergencyOrdersForStation(
  EmergencyFulfillmentOrder left,
  EmergencyFulfillmentOrder right,
  String stationType,
) {
  if (stationType == 'tray' || stationType == 'floor') {
    final leftReady = stationType == 'tray'
        ? left.oldestTrayReadySequence
        : left.oldestReadySequence;
    final rightReady = stationType == 'tray'
        ? right.oldestTrayReadySequence
        : right.oldestReadySequence;
    if (leftReady != null || rightReady != null) {
      if (leftReady == null) return 1;
      if (rightReady == null) return -1;
      final readyOrder = leftReady.compareTo(rightReady);
      if (readyOrder != 0) return readyOrder;
    }
  }
  final receivedOrder = left.createdAt.compareTo(right.createdAt);
  if (receivedOrder != 0) return receivedOrder;
  final queueOrder = left.queueNo.compareTo(right.queueNo);
  if (queueOrder != 0) return queueOrder;
  return left.queueId.compareTo(right.queueId);
}

List<EmergencyFulfillmentOrder> sortEmergencyOrdersForStation(
  Iterable<EmergencyFulfillmentOrder> orders,
  String stationType,
) => (orders.toList(growable: false)
  ..sort(
    (left, right) => compareEmergencyOrdersForStation(left, right, stationType),
  ));

class KitchenChecketMenuGroup {
  const KitchenChecketMenuGroup({
    required this.key,
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.pendingQuantity,
    this.notes,
  });

  final String key;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final int pendingQuantity;
  final String? notes;

  String localizedName(String languageCode) => localizedMenuName({
    'name': _firstEmergencyMenuName(nameKo, nameVi, nameEn),
    'name_ko': nameKo,
    'name_vi': nameVi,
    'name_en': nameEn,
  }, languageCode);
}

class KitchenChecketAllocation {
  const KitchenChecketAllocation({
    required this.itemId,
    required this.queueId,
    required this.sourceKind,
    required this.quantity,
  });

  final String itemId;
  final String queueId;
  final String sourceKind;
  final int quantity;

  Map<String, dynamic> toJson() => {
    'item_id': itemId,
    'queue_id': queueId,
    'source_kind': sourceKind,
    'quantity': quantity,
  };
}

String kitchenChecketGroupKey(EmergencyFulfillmentItem item) => [
  item.menuOptionKey,
  item.nameKo.trim().toLowerCase(),
  item.nameVi.trim().toLowerCase(),
  item.nameEn.trim().toLowerCase(),
  item.notes?.trim() ?? '',
].join('\u0000');

List<KitchenChecketMenuGroup> buildKitchenChecketMenuGroups(
  Iterable<EmergencyFulfillmentOrder> orders,
) {
  final groups = <String, KitchenChecketMenuGroup>{};
  for (final order in sortEmergencyOrdersForStation(orders, 'kitchen')) {
    for (final item in order.kitchenPendingItems()) {
      final pending = item.requiredQuantity - item.kitchenDoneQuantity;
      if (pending <= 0) continue;
      final key = kitchenChecketGroupKey(item);
      final current = groups[key];
      groups[key] = KitchenChecketMenuGroup(
        key: key,
        nameKo: item.nameKo,
        nameVi: item.nameVi,
        nameEn: item.nameEn,
        pendingQuantity: (current?.pendingQuantity ?? 0) + pending,
        notes: item.notes,
      );
    }
  }
  return List.unmodifiable(groups.values);
}

List<KitchenChecketAllocation> allocateKitchenChecketSelections(
  Iterable<EmergencyFulfillmentOrder> orders,
  Map<String, int> selections,
) {
  final remaining = <String, int>{
    for (final entry in selections.entries)
      if (entry.value > 0) entry.key: entry.value,
  };
  final allocations = <KitchenChecketAllocation>[];
  for (final order in sortEmergencyOrdersForStation(orders, 'kitchen')) {
    for (final item in order.kitchenPendingItems()) {
      final key = kitchenChecketGroupKey(item);
      final requested = remaining[key] ?? 0;
      if (requested <= 0) continue;
      final pending = item.requiredQuantity - item.kitchenDoneQuantity;
      final allocated = requested < pending ? requested : pending;
      if (allocated <= 0) continue;
      allocations.add(
        KitchenChecketAllocation(
          itemId: item.id,
          queueId: order.queueId,
          sourceKind: item.sourceKind == 'combo_component'
              ? 'combo_component'
              : 'base',
          quantity: allocated,
        ),
      );
      remaining[key] = requested - allocated;
    }
  }
  if (remaining.values.any((quantity) => quantity > 0)) {
    throw StateError('KDS_CHECKET_SELECTION_STALE');
  }
  return List.unmodifiable(allocations);
}

String _kdsSourceKind(EmergencyFulfillmentItem item) =>
    item.sourceKind == 'combo_component' ? 'combo_component' : 'base';

String _handoffMenuKey(EmergencyFulfillmentItem item) => [
  item.menuOptionKey,
  item.nameKo.trim().toLowerCase(),
  item.nameVi.trim().toLowerCase(),
  item.nameEn.trim().toLowerCase(),
  item.notes?.trim() ?? '',
].join('\u0000');

class TrayFloorTransitionAllocation {
  const TrayFloorTransitionAllocation({
    required this.menuKey,
    required this.itemId,
    required this.queueId,
    required this.sourceKind,
    required this.quantity,
  });

  final String menuKey;
  final String itemId;
  final String queueId;
  final String sourceKind;
  final int quantity;

  TrayFloorTransitionAllocation withQuantity(int value) =>
      TrayFloorTransitionAllocation(
        menuKey: menuKey,
        itemId: itemId,
        queueId: queueId,
        sourceKind: sourceKind,
        quantity: value,
      );

  Map<String, dynamic> toJson() => {
    'item_id': itemId,
    'queue_id': queueId,
    'source_kind': sourceKind,
    'quantity': quantity,
  };
}

class TrayFloorTransitionMenuGroup {
  const TrayFloorTransitionMenuGroup({
    required this.key,
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.quantity,
  });

  final String key;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final int quantity;

  String localizedName(String languageCode) => localizedMenuName({
    'name': _firstEmergencyMenuName(nameKo, nameVi, nameEn),
    'name_ko': nameKo,
    'name_vi': nameVi,
    'name_en': nameEn,
  }, languageCode);
}

class TrayFloorTransitionSummary {
  const TrayFloorTransitionSummary({
    required this.floorLabel,
    required this.groups,
    required this.allocations,
  });

  final String floorLabel;
  final List<TrayFloorTransitionMenuGroup> groups;
  final List<TrayFloorTransitionAllocation> allocations;

  int get totalQuantity =>
      allocations.fold(0, (total, allocation) => total + allocation.quantity);
}

TrayFloorTransitionSummary buildTrayFloorTransitionSummary(
  Iterable<EmergencyFulfillmentOrder> orders,
  String floorLabel,
) {
  final normalizedFloor = floorLabel.trim().toUpperCase();
  final groups = <String, TrayFloorTransitionMenuGroup>{};
  final allocations = <TrayFloorTransitionAllocation>[];
  for (final order in sortEmergencyOrdersForStation(orders, 'tray')) {
    if (order.floorLabel.trim().toUpperCase() != normalizedFloor) continue;
    for (final item in order.trayFloorPendingItems()) {
      final quantity = item.trayPendingQuantity;
      if (quantity <= 0) continue;
      allocations.add(
        TrayFloorTransitionAllocation(
          menuKey: _handoffMenuKey(item),
          itemId: item.id,
          queueId: order.queueId,
          sourceKind: _kdsSourceKind(item),
          quantity: quantity,
        ),
      );
      final key = _handoffMenuKey(item);
      final current = groups[key];
      groups[key] = TrayFloorTransitionMenuGroup(
        key: key,
        nameKo: item.nameKo,
        nameVi: item.nameVi,
        nameEn: item.nameEn,
        quantity: (current?.quantity ?? 0) + quantity,
      );
    }
  }
  return TrayFloorTransitionSummary(
    floorLabel: normalizedFloor,
    groups: List.unmodifiable(groups.values),
    allocations: List.unmodifiable(allocations),
  );
}

TrayFloorTransitionSummary allocateTrayFloorTransitionSelections(
  TrayFloorTransitionSummary summary,
  Map<String, int> selections,
) {
  final availableByKey = {
    for (final group in summary.groups) group.key: group.quantity,
  };
  final remaining = <String, int>{};
  for (final entry in selections.entries) {
    final available = availableByKey[entry.key];
    if (available == null || entry.value < 0 || entry.value > available) {
      throw StateError('KDS_TRAY_FLOOR_SELECTION_STALE');
    }
    if (entry.value > 0) remaining[entry.key] = entry.value;
  }

  final allocations = <TrayFloorTransitionAllocation>[];
  for (final available in summary.allocations) {
    final requested = remaining[available.menuKey] ?? 0;
    if (requested <= 0) continue;
    final quantity = math.min(requested, available.quantity);
    allocations.add(available.withQuantity(quantity));
    remaining[available.menuKey] = requested - quantity;
  }
  if (remaining.values.any((quantity) => quantity > 0)) {
    throw StateError('KDS_TRAY_FLOOR_SELECTION_STALE');
  }

  final groups = summary.groups
      .where((group) => (selections[group.key] ?? 0) > 0)
      .map(
        (group) => TrayFloorTransitionMenuGroup(
          key: group.key,
          nameKo: group.nameKo,
          nameVi: group.nameVi,
          nameEn: group.nameEn,
          quantity: selections[group.key]!,
        ),
      )
      .toList(growable: false);
  return TrayFloorTransitionSummary(
    floorLabel: summary.floorLabel,
    groups: List.unmodifiable(groups),
    allocations: List.unmodifiable(allocations),
  );
}

int trayUnsupportedFloorQuantity(Iterable<EmergencyFulfillmentOrder> orders) =>
    orders
        .where(
          (order) => !RegExp(
            r'^[A-Z0-9][A-Z0-9_-]{0,15}$',
          ).hasMatch(order.floorLabel.trim().toUpperCase()),
        )
        .expand((order) => order.trayFloorPendingItems())
        .fold(0, (total, item) => total + item.trayPendingQuantity);

class CustomerDeliveryAllocation {
  const CustomerDeliveryAllocation({
    required this.itemId,
    required this.queueId,
    required this.sourceKind,
    required this.quantity,
  });

  final String itemId;
  final String queueId;
  final String sourceKind;
  final int quantity;

  CustomerDeliveryAllocation withQuantity(int value) =>
      CustomerDeliveryAllocation(
        itemId: itemId,
        queueId: queueId,
        sourceKind: sourceKind,
        quantity: value,
      );

  Map<String, dynamic> toJson() => {
    'item_id': itemId,
    'queue_id': queueId,
    'source_kind': sourceKind,
    'quantity': quantity,
  };
}

class CustomerDeliveryMenu {
  const CustomerDeliveryMenu({
    required this.key,
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.availableQuantity,
    required this.allocations,
  });

  final String key;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final int availableQuantity;
  final List<CustomerDeliveryAllocation> allocations;

  String localizedName(String languageCode) => localizedMenuName({
    'name': _firstEmergencyMenuName(nameKo, nameVi, nameEn),
    'name_ko': nameKo,
    'name_vi': nameVi,
    'name_en': nameEn,
  }, languageCode);
}

class CustomerDeliveryBox {
  const CustomerDeliveryBox({
    required this.queueId,
    required this.orderId,
    required this.queueNo,
    required this.tableNumber,
    required this.floorLabel,
    required this.createdAt,
    required this.menus,
  });

  final String queueId;
  final String orderId;
  final int queueNo;
  final String tableNumber;
  final String floorLabel;
  final DateTime createdAt;
  final List<CustomerDeliveryMenu> menus;

  int get totalQuantity =>
      menus.fold(0, (total, menu) => total + menu.availableQuantity);
}

List<CustomerDeliveryBox> buildCustomerDeliveryBoxes(
  Iterable<EmergencyFulfillmentOrder> orders,
  String floorLabel,
) {
  final normalizedFloor = floorLabel.trim().toUpperCase();
  final result = <CustomerDeliveryBox>[];
  for (final order in sortEmergencyOrdersForStation(orders, 'floor')) {
    if (order.floorLabel.trim().toUpperCase() != normalizedFloor) continue;
    final grouped = <String, List<CustomerDeliveryAllocation>>{};
    final sourceItems = <String, EmergencyFulfillmentItem>{};
    for (final item in order.customerDeliveryPendingItems()) {
      final quantity = item.readyUnservedQuantity;
      if (quantity <= 0) continue;
      final menuKey = _handoffMenuKey(item);
      sourceItems.putIfAbsent(menuKey, () => item);
      grouped
          .putIfAbsent(menuKey, () => [])
          .add(
            CustomerDeliveryAllocation(
              itemId: item.id,
              queueId: order.queueId,
              sourceKind: _kdsSourceKind(item),
              quantity: quantity,
            ),
          );
    }
    if (grouped.isEmpty) continue;
    final menus = grouped.entries
        .map((entry) {
          final item = sourceItems[entry.key]!;
          return CustomerDeliveryMenu(
            key: '${order.queueId}\u0000${entry.key}',
            nameKo: item.nameKo,
            nameVi: item.nameVi,
            nameEn: item.nameEn,
            availableQuantity: entry.value.fold(
              0,
              (total, allocation) => total + allocation.quantity,
            ),
            allocations: List.unmodifiable(entry.value),
          );
        })
        .toList(growable: false);
    result.add(
      CustomerDeliveryBox(
        queueId: order.queueId,
        orderId: order.orderId,
        queueNo: order.queueNo,
        tableNumber: order.tableNumber,
        floorLabel: order.floorLabel,
        createdAt: order.createdAt,
        menus: List.unmodifiable(menus),
      ),
    );
  }
  return List.unmodifiable(result);
}

List<CustomerDeliveryAllocation> allocateCustomerDeliverySelections(
  Iterable<CustomerDeliveryBox> boxes,
  Map<String, int> selections,
) {
  final allocations = <CustomerDeliveryAllocation>[];
  final knownKeys = <String>{};
  for (final box in boxes) {
    for (final menu in box.menus) {
      knownKeys.add(menu.key);
      var remaining = selections[menu.key] ?? 0;
      if (remaining < 0 || remaining > menu.availableQuantity) {
        throw StateError('KDS_CUSTOMER_DELIVERY_SELECTION_STALE');
      }
      for (final available in menu.allocations) {
        if (remaining <= 0) break;
        final quantity = math.min(remaining, available.quantity);
        allocations.add(available.withQuantity(quantity));
        remaining -= quantity;
      }
      if (remaining > 0) {
        throw StateError('KDS_CUSTOMER_DELIVERY_SELECTION_STALE');
      }
    }
  }
  if (selections.entries.any(
    (entry) => entry.value != 0 && !knownKeys.contains(entry.key),
  )) {
    throw StateError('KDS_CUSTOMER_DELIVERY_SELECTION_STALE');
  }
  return List.unmodifiable(allocations);
}

class LeftoverPackagingTask {
  const LeftoverPackagingTask({
    required this.id,
    required this.orderId,
    required this.queueId,
    required this.queueNo,
    required this.tableNumber,
    required this.floorLabel,
    required this.status,
    required this.requestedAt,
  });

  final String id;
  final String orderId;
  final String queueId;
  final int queueNo;
  final String tableNumber;
  final String floorLabel;
  final String status;
  final DateTime requestedAt;

  factory LeftoverPackagingTask.fromJson(Map<String, dynamic> json) =>
      LeftoverPackagingTask(
        id: json['id']?.toString() ?? '',
        orderId: json['order_id']?.toString() ?? '',
        queueId: json['queue_id']?.toString() ?? '',
        queueNo: _asInt(json['queue_no']),
        tableNumber: json['table_number']?.toString() ?? '-',
        floorLabel: json['floor_label']?.toString() ?? '1F',
        status: json['status']?.toString() ?? 'awaiting_floor_pickup',
        requestedAt:
            DateTime.tryParse(json['requested_at']?.toString() ?? '') ??
            DateTime.now().toUtc(),
      );
}

class EmergencyFulfillmentState {
  const EmergencyFulfillmentState({
    this.operatingWorkflow,
    this.assigned = false,
    this.assignmentResolved = false,
    this.active = false,
    this.isLoading = false,
    this.restaurantId,
    this.sessionId,
    this.stationType,
    this.floorLabel,
    this.serviceAreaCodes = const [],
    this.serviceAreaConfigurationKnown = false,
    this.fulfillmentMode = FulfillmentMode.paperless,
    this.kitchenDirectToFloor = false,
    this.orders = const [],
    this.completedOrders = const [],
    this.completedHistory = const KdsCompletedHistoryStatus(),
    this.boundedJeongabok = false,
    this.leftoverPackagingTasks = const [],
    this.pendingOutboxCount = 0,
    this.pendingQueueIds = const {},
    this.error,
  });

  final Map<String, dynamic>? operatingWorkflow;
  final bool assigned;
  final bool assignmentResolved;
  final bool active;
  final bool isLoading;
  final String? restaurantId;
  final String? sessionId;
  final String? stationType;
  final String? floorLabel;
  final List<String> serviceAreaCodes;
  final bool serviceAreaConfigurationKnown;
  List<String> get servedAreas => serviceAreaCodes.isEmpty
      ? [if (floorLabel != null) floorLabel!]
      : serviceAreaCodes;
  final FulfillmentMode fulfillmentMode;
  final bool kitchenDirectToFloor;
  final List<EmergencyFulfillmentOrder> orders;
  final List<EmergencyFulfillmentOrder> completedOrders;
  final KdsCompletedHistoryStatus completedHistory;
  final bool boundedJeongabok;
  bool get usesBoundedHistory =>
      restaurantId == bunsikKdsStoreId || boundedJeongabok;
  final List<LeftoverPackagingTask> leftoverPackagingTasks;
  final int pendingOutboxCount;
  final Set<String> pendingQueueIds;
  final String? error;

  bool get isDraining => active && !fulfillmentMode.isPaperless;

  EmergencyFulfillmentState copyWith({
    Map<String, dynamic>? operatingWorkflow,
    bool? assigned,
    bool? assignmentResolved,
    bool? active,
    bool? isLoading,
    String? restaurantId,
    String? sessionId,
    String? stationType,
    String? floorLabel,
    List<String>? serviceAreaCodes,
    bool? serviceAreaConfigurationKnown,
    FulfillmentMode? fulfillmentMode,
    bool? kitchenDirectToFloor,
    List<EmergencyFulfillmentOrder>? orders,
    List<EmergencyFulfillmentOrder>? completedOrders,
    KdsCompletedHistoryStatus? completedHistory,
    bool? boundedJeongabok,
    List<LeftoverPackagingTask>? leftoverPackagingTasks,
    int? pendingOutboxCount,
    Set<String>? pendingQueueIds,
    String? error,
    bool clearError = false,
  }) => EmergencyFulfillmentState(
    operatingWorkflow: operatingWorkflow ?? this.operatingWorkflow,
    assigned: assigned ?? this.assigned,
    assignmentResolved: assignmentResolved ?? this.assignmentResolved,
    active: active ?? this.active,
    isLoading: isLoading ?? this.isLoading,
    restaurantId: restaurantId ?? this.restaurantId,
    sessionId: sessionId ?? this.sessionId,
    stationType: stationType ?? this.stationType,
    floorLabel: floorLabel ?? this.floorLabel,
    serviceAreaCodes: serviceAreaCodes ?? this.serviceAreaCodes,
    serviceAreaConfigurationKnown:
        serviceAreaConfigurationKnown ?? this.serviceAreaConfigurationKnown,
    fulfillmentMode: fulfillmentMode ?? this.fulfillmentMode,
    kitchenDirectToFloor: kitchenDirectToFloor ?? this.kitchenDirectToFloor,
    orders: orders ?? this.orders,
    completedOrders: completedOrders ?? this.completedOrders,
    completedHistory: completedHistory ?? this.completedHistory,
    boundedJeongabok: boundedJeongabok ?? this.boundedJeongabok,
    leftoverPackagingTasks:
        leftoverPackagingTasks ?? this.leftoverPackagingTasks,
    pendingOutboxCount: pendingOutboxCount ?? this.pendingOutboxCount,
    pendingQueueIds: pendingQueueIds ?? this.pendingQueueIds,
    error: clearError ? null : (error ?? this.error),
  );

  factory EmergencyFulfillmentState.fromJson(Map<String, dynamic> json) {
    final rawOrders = json['orders'];
    final rawCompletedOrders = json['completed_orders'];
    final rawLeftoverPackagingTasks = json['leftover_packaging_tasks'];
    final stationType = json['station_type']?.toString() ?? 'kitchen';
    final parsedOrders = rawOrders is List
        ? rawOrders
              .whereType<Map>()
              .map(
                (order) => EmergencyFulfillmentOrder.fromJson(
                  Map<String, dynamic>.from(order),
                ),
              )
              .toList(growable: false)
        : const <EmergencyFulfillmentOrder>[];
    return EmergencyFulfillmentState(
      operatingWorkflow: json['operating_workflow'] is Map
          ? Map<String, dynamic>.from(json['operating_workflow'] as Map)
          : null,
      assigned: json['assigned'] == true,
      assignmentResolved: json.containsKey('assigned'),
      active: json['active'] == true,
      kitchenDirectToFloor: json['kitchen_direct_to_floor'] == true,
      restaurantId: json['restaurant_id']?.toString(),
      sessionId: json['session_id']?.toString(),
      stationType: json['station_type']?.toString(),
      floorLabel: json['floor_label']?.toString(),
      serviceAreaConfigurationKnown:
          json['service_area_configuration_known'] == true,
      serviceAreaCodes: (json['service_area_codes'] as List? ?? [])
          .whereType<String>()
          .toList(),
      fulfillmentMode: FulfillmentMode.fromValue(
        json['fulfillment_mode'] ?? 'paperless',
      ),
      orders: sortEmergencyOrdersForStation(parsedOrders, stationType),
      completedOrders: rawCompletedOrders is List
          ? rawCompletedOrders
                .whereType<Map>()
                .map(
                  (order) => EmergencyFulfillmentOrder.fromJson(
                    Map<String, dynamic>.from(order),
                  ),
                )
                .toList(growable: false)
          : const [],
      leftoverPackagingTasks: rawLeftoverPackagingTasks is List
          ? rawLeftoverPackagingTasks
                .whereType<Map>()
                .map(
                  (task) => LeftoverPackagingTask.fromJson(
                    Map<String, dynamic>.from(task),
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }
}

class EmergencyHandoffNotice {
  const EmergencyHandoffNotice({
    required this.orderId,
    required this.queueNo,
    required this.tableNumber,
    required this.itemCount,
    required this.stationType,
  });

  final String orderId;
  final int queueNo;
  final String tableNumber;
  final int itemCount;
  final String stationType;
}

class EmergencyFloorDirectBeverageNotice {
  const EmergencyFloorDirectBeverageNotice({
    required this.orderId,
    required this.queueNo,
    required this.itemCount,
  });

  final String orderId;
  final int queueNo;
  final int itemCount;
}

class EmergencyKitchenAdditionalOrderNotice {
  const EmergencyKitchenAdditionalOrderNotice({
    required this.orderId,
    required this.queueNo,
    required this.tableNumber,
    required this.itemCount,
  });

  final String orderId;
  final int queueNo;
  final String tableNumber;
  final int itemCount;
}

/// Returns positive kitchen-visible quantity changes on already known orders.
///
/// Completed orders are part of the baseline so an additional order that
/// reopens a completed card is announced, while undo/revert operations are not.
/// New order ids are intentionally excluded because the regular new-order
/// alarm owns those notifications.
List<EmergencyKitchenAdditionalOrderNotice>
emergencyKitchenAdditionalOrderNotices(
  EmergencyFulfillmentState previous,
  EmergencyFulfillmentState next,
) {
  if (next.stationType != 'kitchen' ||
      previous.stationType != next.stationType ||
      previous.sessionId != next.sessionId) {
    return const [];
  }

  final previousOrders = <String, EmergencyFulfillmentOrder>{
    // Live rows win over an older, independently loaded history page.
    for (final order in [...previous.completedOrders, ...previous.orders])
      order.orderId: order,
  };
  final notices = <EmergencyKitchenAdditionalOrderNotice>[];
  for (final order in next.orders) {
    final previousOrder = previousOrders[order.orderId];
    if (previousOrder == null) continue;
    final previousQuantities = <String, int>{
      for (final item in previousOrder.displayItemsAt('kitchen'))
        item.id: item.quantity,
    };
    final addedQuantity = order
        .displayItemsAt('kitchen')
        .fold(
          0,
          (total, item) =>
              total +
              (item.quantity - (previousQuantities[item.id] ?? 0)).clamp(
                0,
                item.quantity,
              ),
        );
    if (addedQuantity <= 0) continue;
    notices.add(
      EmergencyKitchenAdditionalOrderNotice(
        orderId: order.orderId,
        queueNo: order.queueNo,
        tableNumber: order.tableNumber,
        itemCount: addedQuantity,
      ),
    );
  }
  notices.sort((left, right) => left.queueNo.compareTo(right.queueNo));
  return notices;
}

/// Returns only positive floor-direct beverage quantity changes.
/// Completed orders are part of the baseline so an undo cannot be announced
/// as a new beverage order.
List<EmergencyFloorDirectBeverageNotice> emergencyFloorDirectBeverageNotices(
  EmergencyFulfillmentState previous,
  EmergencyFulfillmentState next,
) {
  if (next.stationType != 'floor' ||
      previous.stationType != next.stationType ||
      previous.sessionId != next.sessionId) {
    return const [];
  }

  final previousQuantities = <String, int>{
    // Live rows win over an older, independently loaded history page.
    for (final order in [...previous.completedOrders, ...previous.orders])
      for (final item in order.items)
        if (item.isFloorDirect) item.id: item.orderedQuantity,
  };
  final notices = <EmergencyFloorDirectBeverageNotice>[];
  for (final order in next.orders) {
    final addedQuantity = order.items
        .where((item) => item.isFloorDirect)
        .fold(
          0,
          (total, item) =>
              total +
              (item.orderedQuantity - (previousQuantities[item.id] ?? 0)).clamp(
                0,
                item.orderedQuantity,
              ),
        );
    if (addedQuantity <= 0) continue;
    notices.add(
      EmergencyFloorDirectBeverageNotice(
        orderId: order.orderId,
        queueNo: order.queueNo,
        itemCount: addedQuantity,
      ),
    );
  }
  notices.sort((left, right) => left.queueNo.compareTo(right.queueNo));
  return notices;
}

/// Returns only positive kitchen-to-tray or tray-to-floor quantity changes.
/// Completed orders are included in the baseline so undoing an action does not
/// look like a fresh handoff when the order returns to the active board.
List<EmergencyHandoffNotice> emergencyHandoffNotices(
  EmergencyFulfillmentState previous,
  EmergencyFulfillmentState next,
) {
  final stationType = next.stationType ?? '';
  if ((stationType != 'tray' && stationType != 'floor') ||
      previous.stationType != stationType ||
      previous.sessionId != next.sessionId) {
    return const [];
  }

  final previousOrders = <String, EmergencyFulfillmentOrder>{
    // Live rows win over an older, independently loaded history page.
    for (final order in [...previous.completedOrders, ...previous.orders])
      order.orderId: order,
  };
  final notices = <EmergencyHandoffNotice>[];
  for (final order in next.orders) {
    final currentQuantity = order.incomingHandoffQuantityAt(stationType);
    final previousQuantity =
        previousOrders[order.orderId]?.incomingHandoffQuantityAt(stationType) ??
        0;
    final deliveredQuantity = currentQuantity - previousQuantity;
    if (deliveredQuantity <= 0) continue;
    notices.add(
      EmergencyHandoffNotice(
        orderId: order.orderId,
        queueNo: order.queueNo,
        tableNumber: order.tableNumber,
        itemCount: deliveredQuantity,
        stationType: stationType,
      ),
    );
  }
  notices.sort((left, right) => left.queueNo.compareTo(right.queueNo));
  return notices;
}

/// New or additional food is visible to its floor before kitchen handoff.
/// Announce arrival independently of readiness; refreshes and undo operations
/// must not turn previously known quantities into new orders.
Set<String> emergencyFloorOrderArrivalIds(
  EmergencyFulfillmentState previous,
  EmergencyFulfillmentState next,
) {
  if (next.stationType != 'floor' ||
      previous.stationType != next.stationType ||
      previous.restaurantId != next.restaurantId ||
      previous.sessionId != next.sessionId ||
      previous.floorLabel != next.floorLabel ||
      !listEquals(previous.servedAreas, next.servedAreas)) {
    return const {};
  }
  final previousQuantities = <String, int>{
    for (final order in [...previous.completedOrders, ...previous.orders])
      for (final item in order._operationalItems())
        if (!item.isFloorDirect) item.id: item.requiredQuantity,
  };
  return {
    for (final order in next.orders)
      if (!order.isDelivery &&
          !order.isDirectPickup &&
          order._operationalItems().any(
            (item) =>
                !item.isFloorDirect &&
                item.requiredQuantity > (previousQuantities[item.id] ?? 0),
          ))
        order.orderId,
  };
}

enum EmergencyProgressResult { confirmed, queued, unknown, rejected }

class EmergencyFulfillmentNotifier
    extends StateNotifier<EmergencyFulfillmentState> {
  EmergencyFulfillmentNotifier({
    SupabaseClient? client,
    KdsOutboxStore? outbox,
    @visibleForTesting this.actorIdForTesting,
    @visibleForTesting this.enableRealtimeSubscriptions = true,
  }) : _providedClient = client,
       _outbox = outbox ?? KdsOutboxStore(),
       super(const EmergencyFulfillmentState());

  final SupabaseClient? _providedClient;
  final String? Function()? actorIdForTesting;
  String? get _commandActorId =>
      actorIdForTesting?.call() ?? _client.auth.currentUser?.id;
  final KdsOutboxStore _outbox;
  final _progressEventsInFlight = <String>{};
  bool _recoveringProgress = false;
  final bool enableRealtimeSubscriptions;
  SupabaseClient get _client => _providedClient ?? supabase;

  static const _uuid = Uuid();
  // Realtime events are the fast path. Legacy reconciliation is only a bounded
  // safety net and must not become faster when the realtime channel is down.
  static const _handoffRefreshInterval = Duration(seconds: 30);
  static const _connectedHealthRefreshInterval = Duration(seconds: 30);
  static const _pollJitter = Duration(seconds: 5);
  static const _realtimeRefreshDelay = Duration(milliseconds: 100);
  RealtimeChannel? _channel;
  KdsRealtimeSync? _kdsSync;
  KdsSyncMode _syncMode = KdsSyncMode.legacy;
  String? _subscriptionKey;
  Timer? _pollTimer;
  Duration? _pollInterval;
  bool _legacyRealtimeConnected = false;
  int _subscriptionGeneration = 0;
  Timer? _realtimeRefreshTimer;
  Timer? _snapshotRetryTimer;
  Timer? _businessDayTimer;
  bool _refreshing = false;
  bool _refreshRequested = false;
  bool _flushing = false;
  int _snapshotFailureCount = 0;
  int _realtimeRevision = 0;
  final Map<String, int> _ticketRevisions = {};
  final Map<String, Future<void>> _ticketRefreshes = {};
  final Set<String> _progressInFlight = {};
  final math.Random _pollRandom = math.Random();
  final KdsReadCoordinator _jeongabokReads = KdsReadCoordinator();
  final RequestLifetime _kdsReadLifetime = RequestLifetime();
  final RequestLifetime _progressWriteLifetime = RequestLifetime();
  bool _boundedJeongabok = false;
  SupabaseKdsSyncGateway _gateway({bool? bounded}) => SupabaseKdsSyncGateway(
    _client,
    lifetime: _kdsReadLifetime,
    coordinator: (bounded ?? _boundedJeongabok) || _boundedJeongabok
        ? _jeongabokReads
        : null,
    boundedJeongabok: bounded ?? _boundedJeongabok,
  );
  // Foreground snapshots are serialized by _refreshing. History, timing and
  // mode reads share one auxiliary lane: at most two reads per device, with
  // no per-ticket requests and no history work on the handoff critical path.
  Future<void> _bunsikAuxiliaryTail = Future.value();
  Future<void>? _bunsikAuxiliaryRefresh;
  bool _bunsikAuxiliaryRequested = false;
  int _bunsikSnapshotRevision = 0;
  String? _bunsikHistoryScope;
  int _bunsikHistoryGeneration = 0;
  final List<Map<String, dynamic>?> _bunsikHistoryCursors = [null];
  Map<String, dynamic>? _bunsikHistoryNext;

  String _bunsikScope(EmergencyFulfillmentState value) => [
    _client.auth.currentUser?.id ?? '',
    value.restaurantId,
    value.sessionId,
    value.stationType,
    value.floorLabel,
    value.servedAreas.join(','),
    DateTime.now()
        .toUtc()
        .add(const Duration(hours: 7))
        .toIso8601String()
        .substring(0, 10),
  ].join(':');

  Future<T> _bunsikAuxiliaryRead<T>(Future<T> Function() request) {
    final result = _bunsikAuxiliaryTail.then((_) => request());
    _bunsikAuxiliaryTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<void> loadCompletedHistory({int direction = 0}) async {
    if (!mounted ||
        !state.usesBoundedHistory ||
        !state.assigned ||
        state.completedHistory.loading) {
      return;
    }
    final scope = _bunsikScope(state);
    if (_bunsikHistoryScope != scope) return;
    var page = state.completedHistory.page;
    if (direction > 0) {
      if (!state.completedHistory.hasMore || _bunsikHistoryNext == null) return;
      page += 1;
    } else if (direction < 0) {
      if (page == 0) return;
      page -= 1;
    } else {
      page = 0;
    }
    final cursor = direction > 0
        ? _bunsikHistoryNext
        : _bunsikHistoryCursors[page];
    final generation = ++_bunsikHistoryGeneration;
    final previous = state.completedHistory;
    final viewRevision = _realtimeRevision;
    state = state.copyWith(
      completedHistory: KdsCompletedHistoryStatus(
        loading: true,
        page: previous.page,
        hasMore: previous.hasMore,
      ),
    );
    bool current() =>
        mounted &&
        generation == _bunsikHistoryGeneration &&
        scope == _bunsikHistoryScope &&
        scope == _bunsikScope(state);
    try {
      Future<dynamic> request() async {
        if (!current()) return null;
        return _client.rpc(
          state.boundedJeongabok
              ? 'get_jeongabok_kds_completed_page_v1'
              : 'get_bunsik_kds_completed_page_v1',
          params: {
            'p_limit': 50,
            'p_before_completed_at': cursor?['completed_at'],
            'p_before_queue_id': cursor?['queue_id'],
          },
        );
      }

      final raw = await (state.boundedJeongabok
          ? _jeongabokReads.run(request)
          : _bunsikAuxiliaryRead(request));
      if (!current()) return;
      if (state.boundedJeongabok && viewRevision != _realtimeRevision) {
        throw StateError('KDS_HISTORY_CHANGED_DURING_READ');
      }
      if (state.boundedJeongabok &&
          (raw is! Map ||
              raw['sync'] is! Map ||
              !_matchesJeongabokConfig(
                KdsSyncConfig.fromJson(
                  Map<String, dynamic>.from(raw['sync'] as Map),
                ),
              ))) {
        unawaited(_requestKdsBootstrap());
        throw StateError('KDS_HISTORY_ASSIGNMENT_CHANGED');
      }
      if (raw is! Map ||
          raw['orders'] is! List ||
          (raw['orders'] as List).length > 50 ||
          (raw['has_more'] == true && raw['next_cursor'] is! Map)) {
        throw const FormatException('KDS_HISTORY_RESPONSE_INVALID');
      }
      final orders = (raw['orders'] as List)
          .whereType<Map>()
          .map(
            (row) => EmergencyFulfillmentOrder.fromJson(
              Map<String, dynamic>.from(row),
            ),
          )
          .toList(growable: false);
      if (direction > 0) {
        _bunsikHistoryCursors.removeRange(page, _bunsikHistoryCursors.length);
        _bunsikHistoryCursors.add(cursor);
      } else if (direction == 0) {
        _bunsikHistoryCursors.removeRange(1, _bunsikHistoryCursors.length);
      }
      _bunsikHistoryNext = raw['next_cursor'] is Map
          ? Map<String, dynamic>.from(raw['next_cursor'] as Map)
          : null;
      state = state.copyWith(
        completedOrders: orders,
        completedHistory: KdsCompletedHistoryStatus(
          page: page,
          hasMore: raw['has_more'] == true,
        ),
      );
    } catch (_) {
      if (current()) {
        state = state.copyWith(
          completedHistory: KdsCompletedHistoryStatus(
            page: previous.page,
            hasMore: previous.hasMore,
            error: 'KDS_HISTORY_FAILED',
          ),
        );
      }
    }
  }

  Future<void> _refreshBunsikAuxiliary() {
    _bunsikAuxiliaryRequested = true;
    if (_bunsikAuxiliaryRefresh != null) return _bunsikAuxiliaryRefresh!;
    _bunsikAuxiliaryRequested = false;
    return _bunsikAuxiliaryRefresh =
        _bunsikAuxiliaryRead(() async {
          final scope = _bunsikScope(state);
          final snapshotRevision = _bunsikSnapshotRevision;
          final realtimeRevision = _realtimeRevision;
          bool current() =>
              mounted &&
              scope == _bunsikHistoryScope &&
              scope == _bunsikScope(state) &&
              snapshotRevision == _bunsikSnapshotRevision &&
              realtimeRevision == _realtimeRevision;
          if (!current()) return;
          final raw = await _optionalRpc('get_emergency_station_timings');
          if (!current()) {
            if (mounted && scope == _bunsikHistoryScope) {
              _bunsikAuxiliaryRequested = true;
            }
            return;
          }
          final timings = <String, Map>{
            if (raw is List)
              for (final row in raw.whereType<Map>())
                row['queue_id'].toString(): row,
          };
          EmergencyFulfillmentOrder merge(EmergencyFulfillmentOrder order) {
            final timing = timings[order.queueId];
            return timing == null
                ? order
                : order.copyWith(
                    stationStartedAt: _optionalDateTime(
                      timing['station_started_at'],
                    ),
                    clearStationCompletedAt:
                        timing.containsKey('station_completed_at') &&
                        timing['station_completed_at'] == null,
                    stationCompletedAt: _optionalDateTime(
                      timing['station_completed_at'],
                    ),
                  );
          }

          state = state.copyWith(
            orders: state.orders.map(merge).toList(growable: false),
          );
          final mode = await _optionalRpcForBunsikMode();
          if (current() && mode != null) {
            state = state.copyWith(
              fulfillmentMode: FulfillmentMode.fromValue(mode),
            );
          }
        }).whenComplete(() {
          _bunsikAuxiliaryRefresh = null;
          if (_bunsikAuxiliaryRequested &&
              mounted &&
              state.restaurantId == bunsikKdsStoreId) {
            unawaited(_refreshBunsikAuxiliary());
          }
        });
  }

  Future<dynamic> _optionalRpcForBunsikMode() async {
    try {
      return await _client.rpc(
        'get_store_fulfillment_mode',
        params: {'p_store_id': bunsikKdsStoreId},
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> load({bool showLoading = true}) async {
    if (!mounted) return;
    if (_refreshing) {
      _refreshRequested = true;
      return;
    }
    _snapshotRetryTimer?.cancel();
    _snapshotRetryTimer = null;
    _refreshing = true;
    _scheduleBusinessDayRefresh(TimeUtils.currentVietnamBusinessDay());
    final refreshRevision = _realtimeRevision;
    if (showLoading) state = state.copyWith(isLoading: true, clearError: true);
    try {
      final outboxError = await _flushOutbox();
      if (!mounted) return;
      var syncConfig = await _loadKdsSyncConfig();
      _boundedJeongabok = syncConfig.boundedJeongabok;
      if (!mounted) return;
      KdsBootstrap? bootstrap;
      dynamic raw;
      if (syncConfig.mode == KdsSyncMode.active) {
        try {
          bootstrap = await _gateway().loadBootstrap();
          syncConfig = bootstrap.config;
          raw = bootstrap.snapshot;
        } catch (_) {
          if (_boundedJeongabok) rethrow;
          if (!mounted) return;
          // A staged or failed v2 rollout must preserve the established KDS
          // path. The per-store flag can be corrected without blocking work.
          syncConfig = const KdsSyncConfig.legacy();
          raw = await _client.rpc('get_emergency_station_snapshot');
        }
      } else {
        raw = await _client.rpc('get_emergency_station_snapshot');
      }
      if (!mounted) return;
      if (raw is! Map) {
        throw const FormatException('EMERGENCY_SNAPSHOT_RESPONSE_INVALID');
      }
      final json = Map<String, dynamic>.from(raw);
      if (!json.containsKey('assigned')) {
        throw const FormatException('EMERGENCY_ASSIGNMENT_RESPONSE_INVALID');
      }
      _snapshotFailureCount = 0;
      _snapshotRetryTimer?.cancel();
      _snapshotRetryTimer = null;
      final storeId = json['restaurant_id']?.toString();
      if (refreshRevision != _realtimeRevision) {
        _refreshRequested = true;
        return;
      }

      // Publish the authoritative order rows before auxiliary history/timing
      // calls finish. This keeps the foreground alarm aligned with the card
      // appearing on slower tablet networks.
      final immediate = preserveEmergencyStationTimings(
        EmergencyFulfillmentState.fromJson(json),
        state,
      );
      final boundedBunsik = storeId == bunsikKdsStoreId && bootstrap == null;
      final boundedHistory = boundedBunsik || syncConfig.boundedJeongabok;
      final historyScope = boundedHistory ? _bunsikScope(immediate) : null;
      final sameHistoryScope =
          historyScope != null && historyScope == _bunsikHistoryScope;
      if (historyScope != _bunsikHistoryScope) {
        _bunsikHistoryScope = historyScope;
        _bunsikHistoryGeneration += 1;
        _bunsikHistoryCursors.clear();
        _bunsikHistoryCursors.add(null);
        _bunsikHistoryNext = null;
      }
      if (boundedBunsik) _bunsikSnapshotRevision += 1;
      state = immediate.copyWith(
        isLoading: false,
        fulfillmentMode: state.fulfillmentMode,
        boundedJeongabok: syncConfig.boundedJeongabok,
        completedOrders: boundedHistory && !sameHistoryScope
            ? const []
            : state.completedOrders,
        completedHistory: sameHistoryScope
            ? state.completedHistory
            : const KdsCompletedHistoryStatus(),
        pendingOutboxCount: state.pendingOutboxCount,
        pendingQueueIds: state.pendingQueueIds,
        clearError: true,
      );
      if (bootstrap == null) {
        await _subscribe(immediate, syncConfig);
      }
      if (!mounted) return;

      if (syncConfig.boundedJeongabok) {
        final pending = _scopedOutboxRecords(await _outbox.read(), storeId);
        if (!mounted) return;
        state = state.copyWith(
          pendingOutboxCount: pending.length,
          pendingQueueIds: emergencyPendingQueueIds(pending),
          error: outboxError,
          clearError: outboxError == null,
          fulfillmentMode: FulfillmentMode.fromValue(
            bootstrap!.fulfillmentMode,
          ),
        );
        await _subscribe(state, syncConfig);
        return;
      }
      if (boundedBunsik) {
        final pendingRecords = _scopedOutboxRecords(
          await _outbox.read(),
          storeId,
        );
        if (!mounted) return;
        state = state.copyWith(
          pendingOutboxCount: pendingRecords.length,
          pendingQueueIds: emergencyPendingQueueIds(pendingRecords),
          error: outboxError,
          clearError: outboxError == null,
        );
        unawaited(_refreshBunsikAuxiliary());
        return;
      }

      if (bootstrap != null) {
        json['completed_orders'] = bootstrap.completedOrders;
        _mergeStationTimings(json, bootstrap.timings);
        json['fulfillment_mode'] = bootstrap.fulfillmentMode;
      } else {
        final stationData = await Future.wait([
          _optionalRpc('get_emergency_station_today_completed'),
          _optionalRpc('get_emergency_station_timings'),
        ]);
        if (!mounted) return;
        final completed = stationData[0];
        json['completed_orders'] = completed is List ? completed : const [];
        _mergeStationTimings(json, stationData[1]);
        if (storeId != null && storeId.isNotEmpty) {
          try {
            json['fulfillment_mode'] = await _client.rpc(
              'get_store_fulfillment_mode',
              params: {'p_store_id': storeId},
            );
          } catch (_) {
            // Compatibility with the pre-mode migration during staged rollout.
          }
        }
      }
      if (!mounted) return;
      final next = EmergencyFulfillmentState.fromJson(json);
      final pendingRecords = await _outbox.read();
      final currentPendingRecords = _scopedOutboxRecords(
        pendingRecords,
        storeId,
      );
      if (!mounted) return;
      if (refreshRevision != _realtimeRevision) {
        _refreshRequested = true;
        return;
      }
      state = next.copyWith(
        isLoading: false,
        pendingOutboxCount: currentPendingRecords.length,
        pendingQueueIds: emergencyPendingQueueIds(currentPendingRecords),
        error: outboxError,
        clearError: outboxError == null,
      );
      if (bootstrap != null) {
        await _subscribe(state, syncConfig);
      }
    } catch (error, stack) {
      if (kDebugMode) {
        debugPrintStack(stackTrace: stack, label: 'KDS snapshot failed');
      }
      if (!mounted) return;
      _refreshRequested = false;
      _snapshotFailureCount += 1;
      state = state.copyWith(
        isLoading: false,
        error: 'EMERGENCY_SNAPSHOT_FAILED: $error',
      );
      _scheduleSnapshotRetry();
    } finally {
      _refreshing = false;
      if (_refreshRequested && mounted && _snapshotRetryTimer == null) {
        _refreshRequested = false;
        unawaited(load(showLoading: false));
      }
    }
  }

  void _scheduleSnapshotRetry() {
    _snapshotRetryTimer?.cancel();
    final baseDelay = emergencySnapshotRetryDelay(_snapshotFailureCount);
    final jitter = _pollRandom.nextInt(2001);
    _snapshotRetryTimer = Timer(baseDelay + Duration(milliseconds: jitter), () {
      _snapshotRetryTimer = null;
      if (mounted) unawaited(load(showLoading: false));
    });
  }

  void _scheduleBusinessDayRefresh(VietnamBusinessDayWindow businessDay) {
    _businessDayTimer?.cancel();
    _businessDayTimer = Timer(
      businessDay.refreshDelay(DateTime.now().toUtc()),
      () {
        if (mounted) unawaited(load(showLoading: false));
      },
    );
  }

  Future<dynamic> _optionalRpc(String functionName) async {
    try {
      return await _client.rpc(functionName);
    } catch (_) {
      // Compatibility while additive station RPCs roll out.
      return null;
    }
  }

  Future<KdsSyncConfig> _loadKdsSyncConfig() async {
    try {
      return await _gateway(bounded: false).loadConfig();
    } catch (_) {
      if (_boundedJeongabok) rethrow;
      // The additive migration can be deployed before the Flutter client.
      return const KdsSyncConfig.legacy();
    }
  }

  Future<void> _subscribe(
    EmergencyFulfillmentState snapshot,
    KdsSyncConfig syncConfig,
  ) async {
    if (!enableRealtimeSubscriptions) return;
    final storeId = snapshot.restaurantId;
    final subscriptionKey = <String>[
      syncConfig.mode.name,
      syncConfig.boundedSyncVersion.toString(),
      storeId ?? '',
      snapshot.sessionId ?? '',
      snapshot.stationType ?? '',
      snapshot.floorLabel ?? '',
      snapshot.serviceAreaCodes.join(','),
    ].join(':');
    if (_subscriptionKey == subscriptionKey) return;
    await _disposeSubscriptions();
    if (!mounted) return;
    _subscriptionKey = subscriptionKey;
    _syncMode = syncConfig.mode;

    if (storeId == null || storeId.isEmpty) {
      _startPolling();
      return;
    }
    if (syncConfig.mode != KdsSyncMode.legacy) {
      _kdsSync = KdsRealtimeSync(
        client: _client,
        gateway: _gateway(),
        config: KdsSyncConfig(
          mode: syncConfig.mode,
          boundedSyncVersion: syncConfig.boundedSyncVersion,
          revision: syncConfig.revision,
          assigned: snapshot.assigned,
          restaurantId: storeId,
          sessionId: snapshot.sessionId,
          stationType: snapshot.stationType,
          floorLabel: snapshot.floorLabel,
          serviceAreaCodes: snapshot.serviceAreaCodes,
        ),
        onChange: _applyKdsChange,
        onBatch: syncConfig.boundedJeongabok ? _applyKdsBatch : null,
        watchdogInterval: syncConfig.boundedJeongabok
            ? const Duration(seconds: 5)
            : const Duration(seconds: 30),
        onBootstrapRequired: _requestKdsBootstrap,
        onConnected: _onKdsConnected,
        onError: (error, stack) {
          if (kDebugMode) debugPrint('KDS realtime degraded: $error');
        },
      );
      try {
        await _kdsSync!.start();
        if (!mounted) return;
      } catch (error) {
        if (!mounted) return;
        if (syncConfig.boundedJeongabok) rethrow;
        if (kDebugMode) debugPrint('KDS realtime start fallback: $error');
        await _kdsSync?.dispose();
        if (!mounted) return;
        _kdsSync = null;
        _syncMode = KdsSyncMode.legacy;
        _subscriptionKey = 'fallback:$subscriptionKey';
        _subscribeLegacy(storeId);
        return;
      }
      if (syncConfig.mode == KdsSyncMode.active) return;
    }

    _subscribeLegacy(storeId);
  }

  void _subscribeLegacy(String storeId) {
    final generation = _subscriptionGeneration;
    bool current() => mounted && generation == _subscriptionGeneration;
    void refresh(PostgresChangePayload _) {
      if (current()) _requestRealtimeRefresh();
    }

    _channel = _client
        .channel(LiveSyncScope.storeChannel('emergency_fulfillment', storeId))
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'emergency_fulfillment_sessions',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: refresh,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'emergency_order_queue',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: refresh,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'emergency_fulfillment_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (payload) {
            if (current()) _applyRealtimeItemChange(payload);
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'emergency_combo_component_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (payload) {
            if (current()) _applyRealtimeItemChange(payload);
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'emergency_floor_direct_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: refresh,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'emergency_fulfillment_actions',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: refresh,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'emergency_fulfillment_events',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: refresh,
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'leftover_packaging_requests',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: refresh,
        )
        .subscribe((status, [error]) {
          if (!current()) return;
          final connected = status == RealtimeSubscribeStatus.subscribed;
          if (_legacyRealtimeConnected == connected) return;
          _legacyRealtimeConnected = connected;
          _startPolling();
          if (connected) {
            // Close the initial snapshot/subscription gap and recover promptly
            // after reconnection, even if the normal retry is backing off.
            _snapshotRetryTimer?.cancel();
            _snapshotRetryTimer = null;
            _requestRealtimeRefresh();
          }
        });
    _startPolling();
  }

  Future<void> _disposeSubscriptions() async {
    _subscriptionGeneration += 1;
    _legacyRealtimeConnected = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollInterval = null;
    _realtimeRefreshTimer?.cancel();
    _realtimeRefreshTimer = null;
    final channel = _channel;
    _channel = null;
    if (channel != null) await channel.unsubscribe();
    final kdsSync = _kdsSync;
    _kdsSync = null;
    if (kdsSync != null) await kdsSync.dispose();
    _ticketRevisions.clear();
  }

  void _startPolling() {
    final interval = _legacyRealtimeConnected
        ? _connectedHealthRefreshInterval
        : _handoffRefreshInterval;
    if (_pollTimer != null && _pollInterval == interval) return;
    _pollTimer?.cancel();
    _pollInterval = interval;
    _scheduleLegacyPollTick(interval);
  }

  void _scheduleLegacyPollTick(Duration interval) {
    final jitterWindowMs = _pollJitter.inMilliseconds * 2;
    final jitterMs = _pollRandom.nextInt(jitterWindowMs + 1);
    final delay = interval - _pollJitter + Duration(milliseconds: jitterMs);
    _pollTimer = Timer(delay, () {
      _pollTimer = null;
      // The retry timer owns recovery after failure; polling must not bypass it.
      if (mounted && !_refreshing && _snapshotRetryTimer == null) {
        unawaited(load(showLoading: false));
      }
      if (mounted && _syncMode != KdsSyncMode.active) {
        _scheduleLegacyPollTick(interval);
      }
    });
  }

  void _requestRealtimeRefresh() {
    if (!mounted) return;
    _realtimeRevision += 1;
    // Keep a bounded window from the first event, not a debounce that can be
    // postponed indefinitely by a busy station. Known item rows still apply now.
    _realtimeRefreshTimer ??= Timer(_realtimeRefreshDelay, () {
      _realtimeRefreshTimer = null;
      if (mounted && _snapshotRetryTimer == null) {
        unawaited(load(showLoading: false));
      }
    });
  }

  Future<void> refreshFromSignal() async {
    final kdsSync = _kdsSync;
    if (_syncMode == KdsSyncMode.active && kdsSync != null) {
      await kdsSync.catchUp();
      return;
    }
    await load(showLoading: false);
  }

  Future<void> _applyKdsChange(KdsChangeEnvelope change) async {
    if (!mounted) return;
    if (change.restaurantId != state.restaurantId) return;
    if (_syncMode == KdsSyncMode.shadow) {
      await _observeKdsShadowChange(change);
      return;
    }
    if (_syncMode != KdsSyncMode.active) return;
    if (change.sessionId != null &&
        state.sessionId != null &&
        change.sessionId != state.sessionId) {
      await _requestKdsBootstrap();
      return;
    }
    switch (change.kind) {
      case 'bootstrap_required':
        await _requestKdsBootstrap();
        return;
      case 'leftover_changed':
        _applyKdsLeftoverChange(change.payload);
        return;
      default:
        final queueId =
            change.queueId ?? change.payload['queue_id']?.toString();
        if (queueId != null && queueId.isNotEmpty) {
          await _refreshKdsTicket(queueId);
        }
        return;
    }
  }

  Future<void> _observeKdsShadowChange(KdsChangeEnvelope change) async {
    final queueId = change.queueId ?? change.payload['queue_id']?.toString();
    if (queueId == null || queueId.isEmpty) return;
    try {
      final raw = await _client.rpc(
        'observe_kds_shadow_v2',
        params: {'p_queue_id': queueId},
      );
      if (raw is Map && raw['matches'] == false && kDebugMode) {
        debugPrint(
          'KDS shadow parity mismatch: queue=$queueId '
          'revision=${raw['revision']}',
        );
      }
    } catch (error) {
      if (kDebugMode) debugPrint('KDS shadow observation failed: $error');
    }
  }

  Future<void> _refreshKdsTicket(String queueId) =>
      _ticketRefreshes.putIfAbsent(queueId, () async {
        try {
          await _fetchKdsTicket(queueId);
        } finally {
          _ticketRefreshes.remove(queueId);
        }
      });

  Future<void> _fetchKdsTicket(String queueId) async {
    if (_boundedJeongabok) {
      await _refreshKdsTickets([queueId]);
      return;
    }
    final sync = _kdsSync;
    final result = sync == null
        ? await _gateway().loadTicket(queueId)
        : await sync.loadTicket(queueId);
    if (!mounted || !identical(sync, _kdsSync)) return;
    _applyTicketResults(result.revision, {queueId: result.ticket});
  }

  @visibleForTesting
  Future<void> applyKdsBatchForTesting(List<KdsChangeEnvelope> changes) =>
      _applyKdsBatch(changes);

  Future<void> _applyKdsBatch(List<KdsChangeEnvelope> changes) async {
    final generation = _subscriptionGeneration;
    final pending = <String, int>{};
    Future<void> flush() async {
      final entries = pending.entries.toList(growable: false);
      pending.clear();
      for (var offset = 0; offset < entries.length; offset += 50) {
        if (!mounted || generation != _subscriptionGeneration) return;
        final chunk = entries.skip(offset).take(50).toList(growable: false);
        await _refreshKdsTickets(
          chunk.map((e) => e.key).toList(growable: false),
          minimumRevision: chunk.map((e) => e.value).reduce(math.max),
        );
      }
    }

    for (final change in changes) {
      if (!mounted || generation != _subscriptionGeneration) return;
      if (change.kind != 'ticket_invalidated' ||
          (change.sessionId != null && change.sessionId != state.sessionId)) {
        await flush();
        await _applyKdsChange(change);
      } else {
        final id = change.queueId ?? change.payload['queue_id']?.toString();
        if (id != null && id.isNotEmpty) pending[id] = change.revision;
      }
    }
    await flush();
  }

  bool _matchesJeongabokConfig(KdsSyncConfig config) =>
      config.boundedJeongabok &&
      config.restaurantId == state.restaurantId &&
      config.sessionId == state.sessionId &&
      config.stationType == state.stationType &&
      config.floorLabel == state.floorLabel &&
      listEquals(config.servedAreas, state.servedAreas);

  Future<void> _refreshKdsTickets(
    List<String> ids, {
    int minimumRevision = 0,
  }) async {
    final generation = _subscriptionGeneration;
    final viewRevision = _realtimeRevision;
    final scope = _bunsikScope(state);
    final result = await _gateway().loadTickets(ids);
    if (!mounted || generation != _subscriptionGeneration) return;
    if (viewRevision != _realtimeRevision) {
      throw StateError('KDS_BATCH_CHANGED_DURING_READ');
    }
    if (scope != _bunsikScope(state)) {
      throw StateError('KDS_BATCH_SCOPE_CHANGED');
    }
    if (!_matchesJeongabokConfig(result.config)) {
      unawaited(_requestKdsBootstrap());
      throw StateError('KDS_BATCH_ASSIGNMENT_CHANGED');
    }
    if (result.revision < minimumRevision) {
      throw StateError('KDS_BATCH_STALE_REVISION');
    }
    _applyTicketResults(result.revision, result.tickets);
  }

  void _applyTicketResults(
    int revision,
    Map<String, Map<String, dynamic>?> results,
  ) {
    final accepted = <String, EmergencyFulfillmentOrder?>{};
    for (final entry in results.entries) {
      if (revision < (_ticketRevisions[entry.key] ?? 0)) continue;
      _ticketRevisions[entry.key] = revision;
      accepted[entry.key] = entry.value == null
          ? null
          : EmergencyFulfillmentOrder.fromJson(entry.value!);
    }
    if (accepted.isEmpty) return;
    final orders =
        state.orders
            .where((o) => !accepted.containsKey(o.queueId))
            .toList(growable: true)
          ..addAll(accepted.values.whereType<EmergencyFulfillmentOrder>())
          ..sort(
            (a, b) => compareEmergencyOrdersForStation(
              a,
              b,
              state.stationType ?? 'kitchen',
            ),
          );
    final completed = state.completedOrders
        .where(
          (o) =>
              !accepted.containsKey(o.queueId) || accepted[o.queueId] != null,
        )
        .map((o) => accepted[o.queueId] ?? o)
        .toList(growable: false);
    _realtimeRevision += 1;
    state = state.copyWith(
      orders: orders,
      completedOrders: completed,
      clearError: true,
    );
  }

  void _applyKdsLeftoverChange(Map<String, dynamic> payload) {
    final rawTask = payload['task'];
    if (rawTask is! Map) return;
    final task = LeftoverPackagingTask.fromJson(
      Map<String, dynamic>.from(rawTask),
    );
    final station = state.stationType;
    final actionable = switch (station) {
      'kitchen' => task.status == 'awaiting_kitchen_packaging',
      'tray' =>
        task.status == 'awaiting_tray_to_kitchen' ||
            task.status == 'awaiting_tray_return',
      'floor' =>
        state.servedAreas.contains(task.floorLabel) &&
            (task.status == 'awaiting_floor_pickup' ||
                task.status == 'awaiting_floor_delivery'),
      _ => false,
    };
    final tasks = state.leftoverPackagingTasks
        .where((candidate) => candidate.id != task.id)
        .toList(growable: true);
    if (actionable) tasks.add(task);
    tasks.sort((left, right) {
      final requested = left.requestedAt.compareTo(right.requestedAt);
      return requested != 0 ? requested : left.id.compareTo(right.id);
    });
    _realtimeRevision += 1;
    state = state.copyWith(leftoverPackagingTasks: tasks, clearError: true);
  }

  Future<void> _requestKdsBootstrap() async {
    if (!mounted) return;
    // A new bootstrap establishes a new cursor even when assignments match.
    await _disposeSubscriptions();
    _subscriptionKey = null;
    unawaited(load(showLoading: false));
  }

  Future<void> _onKdsConnected() async {
    if (!mounted || _syncMode == KdsSyncMode.legacy) return;
    final error = await _flushOutbox();
    final pendingRecords = await _outbox.read();
    final currentPendingRecords = _scopedOutboxRecords(
      pendingRecords,
      state.restaurantId,
    );
    if (!mounted) return;
    state = state.copyWith(
      pendingOutboxCount: currentPendingRecords.length,
      pendingQueueIds: emergencyPendingQueueIds(currentPendingRecords),
      error: error,
      clearError: error == null,
    );
    await _kdsSync?.catchUp();
  }

  void _applyRealtimeItemChange(PostgresChangePayload payload) {
    if (!_applyRealtimeItemRow(payload.newRecord)) {
      _requestRealtimeRefresh();
    }
  }

  bool _applyRealtimeItemRow(Map<String, dynamic> row) {
    if (row.isEmpty || row['is_cancelled'] == true) return false;
    final itemId = row['id']?.toString();
    if (itemId == null || itemId.isEmpty) return false;

    var found = false;
    final updatesReadySequence = row.containsKey('oldest_ready_sequence');
    final updatesTrayReadySequence = row.containsKey(
      'oldest_tray_ready_sequence',
    );
    EmergencyFulfillmentOrder applyRow(EmergencyFulfillmentOrder order) {
      var orderChanged = false;
      final nextItems = order.items
          .map((item) {
            if (item.id != itemId) return item;
            found = true;
            orderChanged = true;
            return item
                .withStage(
                  'kitchen_started',
                  row.containsKey('kitchen_started_quantity')
                      ? _asInt(row['kitchen_started_quantity'])
                      : item.kitchenStartedQuantity,
                )
                .withStage(
                  'kitchen_done',
                  _asInt(row['kitchen_done_quantity']),
                  preserveKitchenStarted: true,
                )
                .withStage(
                  'tray_received',
                  _asInt(row['tray_received_quantity']),
                )
                .withStage(
                  'tray_dispatched',
                  _asInt(row['tray_dispatched_quantity']),
                )
                .withStage(
                  'floor_served',
                  _asInt(row['floor_served_quantity']),
                  updateOldestReadySequence: updatesReadySequence,
                  oldestReadySequence: row['oldest_ready_sequence'] == null
                      ? null
                      : _asInt(row['oldest_ready_sequence']),
                  updateOldestTrayReadySequence: updatesTrayReadySequence,
                  oldestTrayReadySequence:
                      row['oldest_tray_ready_sequence'] == null
                      ? null
                      : _asInt(row['oldest_tray_ready_sequence']),
                );
          })
          .toList(growable: false);
      if (!orderChanged) return order;
      var nextOrder = order.copyWith(items: nextItems);
      if (updatesReadySequence) {
        final sequences = nextItems
            .map((item) => item.oldestReadySequence)
            .whereType<int>()
            .toList(growable: false);
        nextOrder = nextOrder.copyWith(
          oldestReadySequence: sequences.isEmpty
              ? null
              : sequences.reduce((left, right) => left < right ? left : right),
          clearOldestReadySequence: sequences.isEmpty,
        );
      }
      if (updatesTrayReadySequence) {
        final sequences = nextItems
            .map((item) => item.oldestTrayReadySequence)
            .whereType<int>()
            .toList(growable: false);
        nextOrder = nextOrder.copyWith(
          oldestTrayReadySequence: sequences.isEmpty
              ? null
              : sequences.reduce((left, right) => left < right ? left : right),
          clearOldestTrayReadySequence: sequences.isEmpty,
        );
      }
      return nextOrder;
    }

    final nextOrders = state.orders.map(applyRow).toList(growable: false);
    final nextCompleted = state.completedOrders
        .map(applyRow)
        .toList(growable: false);
    if (!found) return false;

    _realtimeRevision += 1;
    nextOrders.sort(
      (left, right) => compareEmergencyOrdersForStation(
        left,
        right,
        state.stationType ?? 'kitchen',
      ),
    );
    state = state.copyWith(
      orders: nextOrders,
      completedOrders: nextCompleted,
      clearError: true,
    );
    return true;
  }

  @visibleForTesting
  static Duration get handoffRefreshInterval => _handoffRefreshInterval;

  @visibleForTesting
  bool applyRealtimeItemRowForTesting(Map<String, dynamic> row) =>
      _applyRealtimeItemRow(row);

  @visibleForTesting
  Future<String?> flushOutboxForTesting() => _flushOutbox();

  Map<String, dynamic> get _outboxScope => {
    '_outbox_created_at': DateTime.now().millisecondsSinceEpoch,
    '_outbox_store_id': state.restaurantId,
    '_outbox_actor_id': _commandActorId ?? '__unidentified__',
    '_outbox_session_id': state.sessionId,
    '_outbox_station_type': state.stationType,
    '_outbox_floor_label': state.floorLabel,
  };

  bool _ownsOutbox(Map<String, dynamic> payload) =>
      mounted &&
      kdsOutboxScopeMatches(
        payload,
        storeId: state.restaurantId,
        actorId: _commandActorId,
        sessionId: state.sessionId,
        stationType: state.stationType,
        floorLabel: state.floorLabel,
      );

  List<EmergencyOutboxRecord> _scopedOutboxRecords(
    Iterable<EmergencyOutboxRecord> records,
    String? storeId,
  ) => emergencyOutboxRecordsForStore(records, storeId)
      .where((record) {
        final payload = jsonDecode(record.payload);
        return payload is Map &&
            _ownsOutbox(Map<String, dynamic>.from(payload));
      })
      .toList(growable: false);

  static bool _definiteCommandRejection(Object error) =>
      error is PostgrestException &&
      const {'P0001', '42501', '22023', '23503', '23514'}.contains(error.code);

  Future<void> _notePendingProgress(
    Map<String, dynamic> payload,
    String error,
  ) async {
    List<EmergencyOutboxRecord>? records;
    try {
      records = _scopedOutboxRecords(
        await _outbox.read(),
        payload['_outbox_store_id']?.toString(),
      );
    } catch (_) {
      /* No durable queue claim when local storage cannot be read. */
    }
    if (!_ownsOutbox(payload)) return;
    state = state.copyWith(
      pendingOutboxCount: records?.length,
      pendingQueueIds: {
        ...(records == null
            ? state.pendingQueueIds
            : emergencyPendingQueueIds(records)),
        payload['queue_id'] as String,
      },
      error: error,
    );
  }

  Future<EmergencyProgressResult> recordProgress({
    required String itemId,
    required String stage,
    int delta = 1,
  }) async {
    if (mounted && _commandActorId == null) {
      state = state.copyWith(error: 'EMERGENCY_USER_REQUIRED');
      return EmergencyProgressResult.rejected;
    }
    if (!mounted || !_progressInFlight.add(itemId)) {
      return EmergencyProgressResult.rejected;
    }
    String? eventId;
    try {
      final order = [...state.orders, ...state.completedOrders]
          .where((order) => order.items.any((item) => item.id == itemId))
          .firstOrNull;
      final item = order?.items.where((item) => item.id == itemId).firstOrNull;
      if (item == null || state.pendingQueueIds.contains(order!.queueId)) {
        return EmergencyProgressResult.rejected;
      }
      eventId = _uuid.v4();
      _progressEventsInFlight.add(eventId);
      final payload = <String, dynamic>{
        ..._outboxScope,
        '_outbox_progress_journal': 1,
        '_outbox_phase': 'prepared',
        '_outbox_order_item_id': item.orderItemId,
        'event_id': eventId,
        'item_id': itemId,
        'queue_id': order.queueId,
        'stage': stage,
        'delta': delta,
        'floor_direct': item.isFloorDirect,
        'combo_component':
            item.sourceKind == 'combo_component' && !item.isFloorDirect,
        'workflow_v2': item.usesKitchenHandoffWorkflow,
      };
      try {
        // The original identity must survive a lost HTTP response/tab close.
        // A prepared record is NEVER automatically sent by the outbox flusher.
        await _putOutbox(eventId, payload);
      } catch (_) {
        try {
          final saved = (await _outbox.read()).any(
            (record) => record.id == eventId,
          );
          if (!saved) {
            if (_ownsOutbox(payload)) {
              state = state.copyWith(error: 'KDS_PROGRESS_NOT_SAVED');
            }
            return EmergencyProgressResult.rejected;
          }
        } catch (_) {
          /* The local transaction outcome is itself unknown. */
        }
        await _notePendingProgress(payload, 'KDS_PROGRESS_RESULT_UNKNOWN');
        return EmergencyProgressResult.unknown;
      }
      if (!_ownsOutbox(payload)) return EmergencyProgressResult.unknown;
      return await _executePreparedProgress(payload);
    } finally {
      if (eventId != null) _progressEventsInFlight.remove(eventId);
      _progressInFlight.remove(itemId);
    }
  }

  Future<EmergencyProgressResult> _executePreparedProgress(
    Map<String, dynamic> payload,
  ) async {
    final eventId = payload['event_id'] as String;
    final queueId = payload['queue_id'] as String;
    final commandRevision = _realtimeRevision;
    late final Map<String, dynamic> response;
    try {
      response = await _sendProgress(payload);
    } catch (error) {
      if (_definiteCommandRejection(error)) {
        try {
          await _outbox.delete(eventId);
          if (_ownsOutbox(payload)) {
            state = state.copyWith(
              error: (error as PostgrestException).message,
            );
          }
          return EmergencyProgressResult.rejected;
        } catch (_) {
          await _notePendingProgress(payload, 'KDS_PROGRESS_RESULT_UNKNOWN');
          return EmergencyProgressResult.unknown;
        }
      }
      try {
        await _putOutbox(eventId, {...payload, '_outbox_phase': 'queued'});
        await _notePendingProgress(payload, 'EMERGENCY_PROGRESS_QUEUED');
        return EmergencyProgressResult.queued;
      } catch (_) {
        await _notePendingProgress(payload, 'KDS_PROGRESS_RESULT_UNKNOWN');
        return EmergencyProgressResult.unknown;
      }
    }
    try {
      await _outbox.delete(eventId);
    } catch (_) {
      if (_ownsOutbox(payload)) {
        state = state.copyWith(error: 'EMERGENCY_ORDER_REFRESH_PENDING');
      }
    }
    // A confirmed write remains confirmed after logout, assignment change or
    // failed refresh; its response cannot update the new screen's quantities.
    if (!_ownsOutbox(payload)) return EmergencyProgressResult.confirmed;
    final result = _commandResult(response);
    if (commandRevision == _realtimeRevision &&
        (result.containsKey('floor_served_quantity') ||
            result.containsKey('kitchen_done_quantity'))) {
      _applyAuthoritativeProgress(payload['item_id'] as String, result);
    } else {
      await _refreshConfirmedCommand(queueId);
    }
    if (_ownsOutbox(payload) && (payload['delta'] as int) < 0) {
      _restoreReopenedHistoryOrder(queueId);
    }
    return EmergencyProgressResult.confirmed;
  }

  Future<Set<String>> _confirmedProgressRecords(
    List<EmergencyOutboxRecord> records,
  ) async {
    final payloads = <String, Map<String, dynamic>>{
      for (final record in records)
        if (!_progressEventsInFlight.contains(record.id))
          record.id: Map<String, dynamic>.from(
            jsonDecode(record.payload) as Map,
          ),
    };
    if (payloads.isEmpty) return {};
    final ids = payloads.keys.toList(growable: false);
    final confirmed = <String>{};
    final deadline = DateTime.now().add(const Duration(seconds: 15));
    final transport = DeadlineHttpClient(
      _client.rest.httpClient!,
      deadline,
      callTimeout: const Duration(seconds: 15),
      maxResponseBytes: 256 * 1024,
    );
    _kdsReadLifetime.add(transport);
    final db = PostgrestClient(
      _client.rest.url,
      headers: _client.rest.headers,
      httpClient: transport,
    );
    try {
      for (var i = 0; i < ids.length; i += 100) {
        final batch = ids.skip(i).take(100).toList(growable: false);
        final rows = await db.rpc(
          'get_kds_progress_receipts_v1',
          params: {
            'p_store_id': payloads[batch.first]!['_outbox_store_id'],
            'p_operation_ids': batch,
          },
        );
        if (rows is! List || rows.length > batch.length) {
          throw const FormatException('KDS_PROGRESS_RECEIPT_RESPONSE_INVALID');
        }
        final seen = <String>{};
        for (final row in rows) {
          final id = row['event_id']?.toString();
          if (id == null ||
              !batch.contains(id) ||
              !seen.add(id) ||
              !kdsProgressReceiptMatches(payloads[id]!, row)) {
            throw const FormatException('KDS_PROGRESS_RECEIPT_MISMATCH');
          }
          confirmed.add(id);
        }
      }
      return confirmed;
    } finally {
      _kdsReadLifetime.remove(transport);
      transport.close();
    }
  }

  /// An explicit refresh reconciles the original event before retrying it.
  /// Reuse its UUID and immutable payload; never generate a second handoff.
  Future<void> reconcileUnknownProgress() async {
    if (!mounted || _recoveringProgress || _flushing) return;
    _recoveringProgress = true;
    final recoveryScope = _outboxScope;
    try {
      final records = _scopedOutboxRecords(
        await _outbox.read(),
        state.restaurantId,
      );
      final record = records.where((record) {
        final payload = jsonDecode(record.payload) as Map;
        return payload['_outbox_progress_journal'] == 1 &&
            payload['_outbox_phase'] == 'prepared' &&
            !_progressEventsInFlight.contains(record.id);
      }).firstOrNull;
      if (record == null) {
        await load(showLoading: false);
        return;
      }
      final queues = emergencyPendingQueueIds([record]);
      if (records
          .takeWhile((previous) => previous.id != record.id)
          .any(
            (previous) =>
                emergencyPendingQueueIds([previous]).any(queues.contains),
          )) {
        await _flushOutbox();
        return;
      }
      final payload = Map<String, dynamic>.from(
        jsonDecode(record.payload) as Map,
      );
      final confirmed = await _confirmedProgressRecords([record]);
      if (!_ownsOutbox(payload)) return;
      if (confirmed.contains(record.id)) {
        await _outbox.delete(record.id);
        await _refreshConfirmedCommand(payload['queue_id'] as String);
      } else {
        _progressEventsInFlight.add(record.id);
        try {
          await _executePreparedProgress(payload);
        } finally {
          _progressEventsInFlight.remove(record.id);
        }
      }
      if (!_ownsOutbox(payload)) return;
      final remaining = _scopedOutboxRecords(
        await _outbox.read(),
        state.restaurantId,
      );
      state = state.copyWith(
        pendingOutboxCount: remaining.length,
        pendingQueueIds: emergencyPendingQueueIds(remaining),
        clearError:
            remaining.isEmpty &&
            const {
              'KDS_PROGRESS_RESULT_UNKNOWN',
              'EMERGENCY_PROGRESS_QUEUED',
            }.contains(state.error),
      );
    } catch (_) {
      if (_ownsOutbox(recoveryScope)) {
        state = state.copyWith(error: 'KDS_PROGRESS_RESULT_UNKNOWN');
      }
    } finally {
      _recoveringProgress = false;
    }
  }

  Future<void> _refreshConfirmedCommand(String queueId) async {
    try {
      await _refreshKdsTicket(queueId);
    } catch (_) {
      // The write already committed. Never enqueue it again because the
      // following read failed; broadcast/reconciliation will refresh it.
      if (mounted) {
        state = state.copyWith(error: 'EMERGENCY_ORDER_REFRESH_PENDING');
      }
    }
  }

  void _restoreReopenedHistoryOrder(String queueId) {
    final order = state.completedOrders
        .where((order) => order.queueId == queueId)
        .firstOrNull;
    if (order == null ||
        order.isRecentlyCompleteAt(state.stationType ?? 'kitchen')) {
      return;
    }
    state = state.copyWith(
      orders: [
        ...state.orders.where((current) => current.queueId != queueId),
        order,
      ],
      completedOrders: state.completedOrders
          .where((current) => current.queueId != queueId)
          .toList(growable: false),
    );
  }

  Future<bool> completeOrder({required String queueId}) async {
    final order = state.orders
        .where((candidate) => candidate.queueId == queueId)
        .firstOrNull;
    if (order == null || state.pendingQueueIds.contains(queueId)) return false;
    final actionId = _uuid.v4();
    final payload = <String, dynamic>{
      ..._outboxScope,
      'kind': order.usesKitchenHandoffWorkflow && state.stationType == 'floor'
          ? 'serve_ready_order'
          : 'complete_order',
      'queue_id': queueId,
      'action_id': actionId,
    };
    try {
      await _sendOutboxPayload(payload);
    } catch (error) {
      if (!mounted) return false;
      if (error is PostgrestException) {
        state = state.copyWith(error: error.message);
        return false;
      }
      try {
        await _putOutbox(actionId, payload);
        if (!mounted) return true;
        state = state.copyWith(
          pendingOutboxCount: state.pendingOutboxCount + 1,
          pendingQueueIds: {...state.pendingQueueIds, queueId},
          error: 'EMERGENCY_ORDER_ACTION_QUEUED',
        );
        return true;
      } catch (_) {
        if (mounted) {
          state = state.copyWith(error: 'EMERGENCY_ORDER_ACTION_FAILED');
        }
        return false;
      }
    }
    await _refreshConfirmedCommand(queueId);
    return true;
  }

  Future<void> _refreshConfirmedQueues(Iterable<String> queueIds) async {
    if (!_boundedJeongabok) {
      await load(showLoading: false);
      return;
    }
    try {
      final ids = queueIds.toSet().toList(growable: false);
      for (var i = 0; i < ids.length; i += 50) {
        await _refreshKdsTickets(ids.skip(i).take(50).toList(growable: false));
      }
    } catch (_) {
      // The command is committed. Recovery re-reads through the watchdog;
      // never enqueue the write again because its follow-up read failed.
      if (mounted) {
        state = state.copyWith(error: 'KDS_CONFIRMED_REFRESH_FAILED');
      }
    }
  }

  Future<bool> completeKitchenChecketBatch(Map<String, int> selections) async {
    List<KitchenChecketAllocation> allocations;
    try {
      allocations = allocateKitchenChecketSelections(state.orders, selections);
    } catch (_) {
      state = state.copyWith(error: 'KDS_CHECKET_SELECTION_STALE');
      return false;
    }
    if (allocations.isEmpty) return false;
    final requestId = _uuid.v4();
    final payload = <String, dynamic>{
      ..._outboxScope,
      'kind': 'kitchen_checket_batch',
      'request_id': requestId,
      'allocations': allocations
          .map((allocation) => allocation.toJson())
          .toList(growable: false),
    };
    try {
      await _sendOutboxPayload(payload);
      await _refreshConfirmedQueues(allocations.map((a) => a.queueId));
      return true;
    } catch (error) {
      if (error is PostgrestException) {
        state = state.copyWith(error: error.message);
        return false;
      }
      try {
        await _putOutbox(requestId, payload);
        state = state.copyWith(
          pendingOutboxCount: state.pendingOutboxCount + 1,
          pendingQueueIds: {
            ...state.pendingQueueIds,
            ...allocations.map((allocation) => allocation.queueId),
          },
          error: 'KDS_CHECKET_BATCH_QUEUED',
        );
        return true;
      } catch (_) {
        state = state.copyWith(error: 'KDS_CHECKET_BATCH_FAILED');
        return false;
      }
    }
  }

  Future<bool> completeTrayFloorTransition(
    TrayFloorTransitionSummary summary,
  ) async {
    if (summary.allocations.isEmpty) return false;
    final requestId = _uuid.v4();
    final payload = <String, dynamic>{
      ..._outboxScope,
      'kind': 'tray_floor_batch',
      'request_id': requestId,
      'floor_label': summary.floorLabel,
      'allocations': summary.allocations
          .map((allocation) => allocation.toJson())
          .toList(growable: false),
    };
    try {
      await _sendOutboxPayload(payload);
      await _refreshConfirmedQueues(summary.allocations.map((a) => a.queueId));
      return true;
    } catch (error) {
      if (error is PostgrestException) {
        state = state.copyWith(error: error.message);
        return false;
      }
      try {
        await _putOutbox(requestId, payload);
        state = state.copyWith(
          pendingOutboxCount: state.pendingOutboxCount + 1,
          pendingQueueIds: {
            ...state.pendingQueueIds,
            ...summary.allocations.map((allocation) => allocation.queueId),
          },
          error: 'KDS_TRAY_FLOOR_BATCH_QUEUED',
        );
        return true;
      } catch (_) {
        state = state.copyWith(error: 'KDS_TRAY_FLOOR_BATCH_FAILED');
        return false;
      }
    }
  }

  Future<bool> completeCustomerDeliveryBatch(
    List<CustomerDeliveryAllocation> allocations,
  ) async {
    if (allocations.isEmpty) return false;
    final requestId = _uuid.v4();
    final payload = <String, dynamic>{
      ..._outboxScope,
      'kind': 'customer_delivery_batch',
      'request_id': requestId,
      'allocations': allocations
          .map((allocation) => allocation.toJson())
          .toList(growable: false),
    };
    try {
      await _sendOutboxPayload(payload);
      await _refreshConfirmedQueues(allocations.map((a) => a.queueId));
      return true;
    } catch (error) {
      if (error is PostgrestException) {
        state = state.copyWith(error: error.message);
        return false;
      }
      try {
        await _putOutbox(requestId, payload);
        state = state.copyWith(
          pendingOutboxCount: state.pendingOutboxCount + 1,
          pendingQueueIds: {
            ...state.pendingQueueIds,
            ...allocations.map((allocation) => allocation.queueId),
          },
          error: 'KDS_CUSTOMER_DELIVERY_BATCH_QUEUED',
        );
        return true;
      } catch (_) {
        state = state.copyWith(error: 'KDS_CUSTOMER_DELIVERY_BATCH_FAILED');
        return false;
      }
    }
  }

  Future<bool> advanceLeftoverPackaging(LeftoverPackagingTask task) async {
    final eventId = _uuid.v4();
    final payload = <String, dynamic>{
      ..._outboxScope,
      'kind': 'advance_leftover_packaging',
      'request_id': task.id,
      'queue_id': task.queueId,
      'event_id': eventId,
    };
    final previous = state;
    _realtimeRevision += 1;
    state = state.copyWith(
      leftoverPackagingTasks: state.leftoverPackagingTasks
          .where((candidate) => candidate.id != task.id)
          .toList(growable: false),
      clearError: true,
    );
    try {
      await _sendOutboxPayload(payload);
      if (_syncMode != KdsSyncMode.active) {
        await load(showLoading: false);
      }
      return true;
    } catch (error) {
      if (error is PostgrestException) {
        state = previous.copyWith(error: error.message);
        return false;
      }
      try {
        await _putOutbox(eventId, payload);
        state = state.copyWith(
          pendingOutboxCount: state.pendingOutboxCount + 1,
          pendingQueueIds: {...state.pendingQueueIds, task.queueId},
          error: 'LEFTOVER_PACKAGING_ACTION_QUEUED',
        );
        return true;
      } catch (_) {
        state = previous.copyWith(error: 'LEFTOVER_PACKAGING_ACTION_FAILED');
        return false;
      }
    }
  }

  Future<bool> revertOrder({
    required String queueId,
    required String actionId,
  }) async {
    final revertId = _uuid.v4();
    final payload = <String, dynamic>{
      ..._outboxScope,
      'kind': 'revert_order',
      'queue_id': queueId,
      'action_id': actionId,
      'revert_id': revertId,
    };
    try {
      await _sendOutboxPayload(payload);
      if (_syncMode == KdsSyncMode.active) {
        try {
          await _refreshKdsTicket(queueId);
        } catch (error) {
          if (kDebugMode) debugPrint('KDS ticket refresh deferred: $error');
        }
      } else {
        await load(showLoading: false);
      }
      return true;
    } catch (error) {
      if (error is PostgrestException) {
        state = state.copyWith(error: error.message);
        return false;
      }
      try {
        await _putOutbox(revertId, payload);
        state = state.copyWith(
          pendingOutboxCount: state.pendingOutboxCount + 1,
          pendingQueueIds: {...state.pendingQueueIds, queueId},
          error: 'EMERGENCY_ORDER_ACTION_QUEUED',
        );
        return true;
      } catch (_) {
        state = state.copyWith(error: 'EMERGENCY_ORDER_REVERT_FAILED');
        return false;
      }
    }
  }

  void _applyAuthoritativeProgress(String itemId, Map<String, dynamic> result) {
    final matchingItem = [...state.orders, ...state.completedOrders]
        .expand((order) => order.items)
        .where((item) => item.id == itemId)
        .cast<EmergencyFulfillmentItem?>()
        .firstWhere((_) => true, orElse: () => null);
    if (matchingItem == null) return;
    _applyRealtimeItemRow({
      'id': itemId,
      'is_cancelled': false,
      'kitchen_started_quantity': result.containsKey('kitchen_started_quantity')
          ? result['kitchen_started_quantity']
          : matchingItem.kitchenStartedQuantity,
      'kitchen_done_quantity': result.containsKey('kitchen_done_quantity')
          ? result['kitchen_done_quantity']
          : matchingItem.kitchenDoneQuantity,
      'tray_received_quantity': result.containsKey('tray_received_quantity')
          ? result['tray_received_quantity']
          : matchingItem.trayReceivedQuantity,
      'tray_dispatched_quantity': result.containsKey('tray_dispatched_quantity')
          ? result['tray_dispatched_quantity']
          : matchingItem.trayDispatchedQuantity,
      'floor_served_quantity': result.containsKey('floor_served_quantity')
          ? result['floor_served_quantity']
          : matchingItem.floorServedQuantity,
      if (result.containsKey('oldest_ready_sequence'))
        'oldest_ready_sequence': result['oldest_ready_sequence'],
      if (result.containsKey('oldest_tray_ready_sequence'))
        'oldest_tray_ready_sequence': result['oldest_tray_ready_sequence'],
    });
  }

  Map<String, dynamic> _commandResult(Map<String, dynamic> response) {
    final result = response['result'];
    return result is Map
        ? Map<String, dynamic>.from(result)
        : Map<String, dynamic>.from(response);
  }

  Future<dynamic> _commandRpc(
    String name, {
    required Map<String, dynamic> params,
    DateTime? deadline,
  }) async {
    final operationDeadline = DateTime.now().add(const Duration(seconds: 15));
    final transport = DeadlineHttpClient(
      _client.rest.httpClient!,
      deadline != null && deadline.isBefore(operationDeadline)
          ? deadline
          : operationDeadline,
      callTimeout: const Duration(seconds: 15),
    );
    _progressWriteLifetime.add(transport);
    final db = PostgrestClient(
      _client.rest.url,
      headers: _client.rest.headers,
      httpClient: transport,
    );
    try {
      return await db.rpc(name, params: params);
    } finally {
      _progressWriteLifetime.remove(transport);
      transport.close();
    }
  }

  Future<Map<String, dynamic>> _sendProgress(
    Map<String, dynamic> payload, {
    DateTime? deadline,
  }) async {
    if (payload['workflow_v2'] == true) {
      final sourceKind = payload['floor_direct'] == true
          ? 'floor_direct'
          : payload['combo_component'] == true
          ? 'combo_component'
          : 'base';
      final raw = await _commandRpc(
        'kds_record_station_progress_v3',
        deadline: deadline,
        params: {
          'p_item_id': payload['item_id'],
          'p_source_kind': sourceKind,
          'p_action': payload['stage'],
          'p_delta': payload['delta'],
          'p_event_id': payload['event_id'],
        },
      );
      return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    }
    if (_syncMode == KdsSyncMode.active) {
      final sourceKind = payload['floor_direct'] == true
          ? 'floor_direct'
          : payload['combo_component'] == true
          ? 'combo_component'
          : 'base';
      final raw = await _commandRpc(
        'kds_record_progress_v2',
        deadline: deadline,
        params: {
          'p_item_id': payload['item_id'],
          'p_stage': payload['stage'],
          'p_delta': payload['delta'],
          'p_event_id': payload['event_id'],
          'p_source_kind': sourceKind,
        },
      );
      return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    }
    if (payload['floor_direct'] == true) {
      final raw = await _commandRpc(
        'emergency_record_floor_direct_progress',
        deadline: deadline,
        params: {
          'p_floor_direct_item_id': payload['item_id'],
          'p_delta': payload['delta'],
          'p_event_id': payload['event_id'],
        },
      );
      return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    }
    if (payload['combo_component'] == true) {
      final raw = await _commandRpc(
        'emergency_record_combo_component_progress',
        deadline: deadline,
        params: {
          'p_component_item_id': payload['item_id'],
          'p_stage': payload['stage'],
          'p_delta': payload['delta'],
          'p_event_id': payload['event_id'],
        },
      );
      return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
    }
    final raw = await _commandRpc(
      'emergency_record_progress',
      deadline: deadline,
      params: {
        'p_fulfillment_item_id': payload['item_id'],
        'p_stage': payload['stage'],
        'p_delta': payload['delta'],
        'p_event_id': payload['event_id'],
      },
    );
    return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
  }

  Future<Map<String, dynamic>> _sendOutboxPayload(
    Map<String, dynamic> payload, {
    DateTime? deadline,
  }) async {
    // The route-aware wrappers delegate food work to the legacy
    // 'emergency_complete_order_stage' / 'emergency_revert_order_action'
    // contracts, then atomically include floor-direct beverage lines.
    switch (payload['kind']) {
      case 'kitchen_checket_batch':
        final raw = await _commandRpc(
          'kds_complete_kitchen_batch_v1',
          deadline: deadline,
          params: {
            'p_request_id': payload['request_id'],
            'p_allocations': payload['allocations'],
          },
        );
        return raw is Map
            ? Map<String, dynamic>.from(raw)
            : <String, dynamic>{};
      case 'tray_floor_batch':
        final raw = await _commandRpc(
          'kds_dispatch_tray_floor_batch_v1',
          deadline: deadline,
          params: {
            'p_request_id': payload['request_id'],
            'p_floor_label': payload['floor_label'],
            'p_allocations': payload['allocations'],
          },
        );
        return raw is Map
            ? Map<String, dynamic>.from(raw)
            : <String, dynamic>{};
      case 'customer_delivery_batch':
        final raw = await _commandRpc(
          'kds_complete_customer_delivery_batch_v1',
          deadline: deadline,
          params: {
            'p_request_id': payload['request_id'],
            'p_allocations': payload['allocations'],
          },
        );
        return raw is Map
            ? Map<String, dynamic>.from(raw)
            : <String, dynamic>{};
      case 'serve_ready_order':
        final raw = await _commandRpc(
          'kds_serve_ready_order_v3',
          deadline: deadline,
          params: {
            'p_queue_id': payload['queue_id'],
            'p_action_id': payload['action_id'],
          },
        );
        return raw is Map
            ? Map<String, dynamic>.from(raw)
            : <String, dynamic>{};
      case 'complete_order':
        final raw = await _commandRpc(
          _syncMode == KdsSyncMode.active
              ? 'kds_complete_order_v2'
              : 'emergency_complete_route_order_stage',
          deadline: deadline,
          params: {
            'p_queue_id': payload['queue_id'],
            'p_action_id': payload['action_id'],
          },
        );
        return raw is Map
            ? Map<String, dynamic>.from(raw)
            : <String, dynamic>{};
      case 'revert_order':
        final raw = await _commandRpc(
          _syncMode == KdsSyncMode.active
              ? 'kds_revert_order_v2'
              : 'emergency_revert_route_order_action',
          deadline: deadline,
          params: {
            'p_queue_id': payload['queue_id'],
            'p_action_id': payload['action_id'],
            'p_revert_id': payload['revert_id'],
          },
        );
        return raw is Map
            ? Map<String, dynamic>.from(raw)
            : <String, dynamic>{};
      case 'advance_leftover_packaging':
        final raw = await _commandRpc(
          _syncMode == KdsSyncMode.active
              ? 'kds_advance_leftover_v2'
              : 'emergency_advance_leftover_packaging',
          deadline: deadline,
          params: {
            'p_request_id': payload['request_id'],
            'p_event_id': payload['event_id'],
          },
        );
        return raw is Map
            ? Map<String, dynamic>.from(raw)
            : <String, dynamic>{};
      default:
        return _sendProgress(payload, deadline: deadline);
    }
  }

  Future<void> _putOutbox(String id, Map<String, dynamic> payload) async {
    final storeId =
        payload['_outbox_store_id']?.toString() ?? state.restaurantId;
    if (storeId == null || storeId.isEmpty) {
      throw StateError('KDS_OUTBOX_STORE_SCOPE_MISSING');
    }
    await _outbox.put(
      id,
      jsonEncode({...payload, '_outbox_store_id': storeId}),
    );
  }

  Future<String?> _flushOutbox() async {
    if (_flushing) return null;
    _flushing = true;
    String? resultError;
    try {
      final records = _scopedOutboxRecords(
        await _outbox.read(),
        state.restaurantId,
      ).take(2000).toList(growable: false);
      final progress = records
          .where(
            (record) =>
                (jsonDecode(record.payload)
                    as Map)['_outbox_progress_journal'] ==
                1,
          )
          .toList(growable: false);
      var canReadResults = true;
      Set<String> confirmed = {};
      try {
        confirmed = await _confirmedProgressRecords(progress);
      } catch (_) {
        canReadResults = false;
        resultError = 'KDS_PROGRESS_RESULT_UNKNOWN';
      }
      final blockedQueues = <String>{};
      final flushDeadline = DateTime.now().add(const Duration(seconds: 15));
      var sends = 0;
      for (final record in records) {
        final payload = Map<String, dynamic>.from(
          jsonDecode(record.payload) as Map,
        );
        if (!_ownsOutbox(payload)) continue;
        if (_progressEventsInFlight.contains(record.id)) {
          blockedQueues.addAll(emergencyPendingQueueIds([record]));
          continue;
        }
        final journal = payload['_outbox_progress_journal'] == 1;
        if (journal && confirmed.contains(record.id)) {
          await _outbox.delete(record.id);
          continue;
        }
        if (journal &&
            (!canReadResults || payload['_outbox_phase'] != 'queued')) {
          resultError = 'KDS_PROGRESS_RESULT_UNKNOWN';
          blockedQueues.addAll(emergencyPendingQueueIds([record]));
          continue; // A tab may have closed either side of the original commit.
        }
        if (emergencyPendingQueueIds([record]).any(blockedQueues.contains)) {
          continue;
        }
        try {
          if (sends >= 20 || DateTime.now().isAfter(flushDeadline)) break;
          // If this process disappears during replay, the next one queries the
          // original result and requires explicit recovery before a new send.
          if (journal) {
            await _putOutbox(record.id, {
              ...payload,
              '_outbox_phase': 'prepared',
            });
          }
          if (!_ownsOutbox(payload)) {
            break;
          }
          sends++;
          await _sendOutboxPayload(payload, deadline: flushDeadline);
          await _outbox.delete(record.id);
        } catch (error) {
          if (journal) {
            if (!_definiteCommandRejection(error)) {
              try {
                await _putOutbox(record.id, {
                  ...payload,
                  '_outbox_phase': 'queued',
                });
                resultError = 'EMERGENCY_PROGRESS_QUEUED';
              } catch (_) {
                resultError = 'KDS_PROGRESS_RESULT_UNKNOWN';
              }
            } else {
              resultError = 'KDS_PROGRESS_RESULT_UNKNOWN';
            }
            break;
          }
          if (_definiteCommandRejection(error)) {
            await _outbox.delete(record.id);
            resultError = (error as PostgrestException).message;
          } else {
            break;
          } // Never delete a legacy event on a gateway/timeout error.
        }
      }
    } finally {
      _flushing = false;
    }
    return resultError;
  }

  @override
  void dispose() {
    _kdsReadLifetime.dispose();
    _progressWriteLifetime.dispose();
    _subscriptionGeneration += 1;
    _realtimeRefreshTimer?.cancel();
    _pollTimer?.cancel();
    _snapshotRetryTimer?.cancel();
    _businessDayTimer?.cancel();
    unawaited(_channel?.unsubscribe());
    unawaited(_kdsSync?.dispose());
    super.dispose();
  }
}

@visibleForTesting
Set<String> emergencyPendingQueueIds(Iterable<EmergencyOutboxRecord> records) {
  final queueIds = <String>{};
  for (final record in records) {
    try {
      final decoded = jsonDecode(record.payload);
      if (decoded is! Map) continue;
      final directQueueId = decoded['queue_id']?.toString();
      if (directQueueId != null && directQueueId.isNotEmpty) {
        queueIds.add(directQueueId);
      }
      final allocations = decoded['allocations'];
      if (allocations is! List) continue;
      for (final allocation in allocations.whereType<Map>()) {
        final queueId = allocation['queue_id']?.toString();
        if (queueId != null && queueId.isNotEmpty) queueIds.add(queueId);
      }
    } catch (_) {
      // Storage adapters surface corrupt records; direct fixture inputs are
      // ignored here because they cannot identify a pending queue safely.
    }
  }
  return queueIds;
}

@visibleForTesting
List<EmergencyOutboxRecord> emergencyOutboxRecordsForStore(
  Iterable<EmergencyOutboxRecord> records,
  String? storeId,
) {
  if (storeId == null || storeId.isEmpty) return const [];
  return records
      .where((record) {
        try {
          final decoded = jsonDecode(record.payload);
          if (decoded is! Map) return false;
          final recordStoreId = decoded['_outbox_store_id']?.toString();
          // Pre-scope records remain replayable under server-side RLS for a
          // backwards-compatible migration. Every new record carries a scope.
          return recordStoreId == null ||
              recordStoreId.isEmpty ||
              recordStoreId == storeId;
        } catch (_) {
          return false;
        }
      })
      .toList(growable: false);
}

final emergencyFulfillmentProvider =
    StateNotifierProvider<
      EmergencyFulfillmentNotifier,
      EmergencyFulfillmentState
    >((ref) => EmergencyFulfillmentNotifier());

int _asInt(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};

String? _firstEmergencyMenuName(String ko, String vi, String en) {
  for (final value in [ko, vi, en]) {
    final cleaned = value.trim();
    if (cleaned.isNotEmpty) return cleaned;
  }
  return null;
}
