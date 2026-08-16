import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/fulfillment_mode.dart';
import '../../core/services/emergency_web_bridge.dart';
import '../../core/utils/live_sync_scope.dart';
import '../../main.dart';

String formatEmergencyElapsed(Duration elapsed) {
  final totalSeconds = elapsed.inSeconds < 0 ? 0 : elapsed.inSeconds;
  final minutes = totalSeconds ~/ 60;
  final seconds = totalSeconds % 60;
  return '${minutes.toString().padLeft(2, '0')}:'
      '${seconds.toString().padLeft(2, '0')}';
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

  String localizedName(String languageCode) => switch (languageCode) {
    'vi' => nameVi.trim().isEmpty ? 'Món' : nameVi,
    'en' => nameEn.trim().isEmpty ? 'Item' : nameEn,
    _ => nameKo.trim().isEmpty ? '메뉴' : nameKo,
  };

  factory EmergencyComboComponent.fromJson(
    Map<String, dynamic> json,
  ) => EmergencyComboComponent(
    menuItemId: json['menu_item_id']?.toString() ?? '',
    nameKo: json['name_ko']?.toString() ?? json['label']?.toString() ?? '메뉴',
    nameVi: json['name_vi']?.toString() ?? json['label']?.toString() ?? 'Món',
    nameEn: json['name_en']?.toString() ?? json['label']?.toString() ?? 'Item',
    quantity: _asInt(json['quantity']),
    isTotalQuantity: json['is_total_quantity'] == true,
    fulfillmentRoute:
        json['fulfillment_route']?.toString() ?? 'kitchen_tray_floor',
  );
}

class EmergencyFulfillmentDisplayItem {
  const EmergencyFulfillmentDisplayItem({
    required this.id,
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.quantity,
    required this.completed,
    required this.readyFromPreviousStage,
    required this.readOnly,
  });

  final String id;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final int quantity;
  final bool completed;
  final bool readyFromPreviousStage;
  final bool readOnly;

  String get paperlessName => nameVi.trim().isEmpty ? 'Món' : nameVi;

  String localizedName(String languageCode) => switch (languageCode) {
    'vi' => nameVi.trim().isEmpty ? 'Món' : nameVi,
    'en' => nameEn.trim().isEmpty ? 'Item' : nameEn,
    _ => nameKo.trim().isEmpty ? '메뉴' : nameKo,
  };
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
    this.fulfillmentRoute = 'kitchen_tray_floor',
    this.lineKey = 'base',
    this.sourceKind = 'order_item',
    this.comboComponents = const [],
  });

  final String id;
  final String orderItemId;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final int orderedQuantity;
  final int kitchenDoneQuantity;
  final int trayReceivedQuantity;
  final int trayDispatchedQuantity;
  final int floorServedQuantity;
  final bool needsReview;
  final String fulfillmentRoute;
  final String lineKey;
  final String sourceKind;
  final List<EmergencyComboComponent> comboComponents;

  bool get isFloorDirect => fulfillmentRoute == 'floor_direct';
  String get paperlessName => nameVi.trim().isEmpty ? 'Món' : nameVi;

  bool isActionableAt(String stationType) => switch (stationType) {
    'kitchen' => !isFloorDirect && kitchenDoneQuantity < orderedQuantity,
    'tray' =>
      !isFloorDirect &&
          (trayReceivedQuantity < kitchenDoneQuantity ||
              trayDispatchedQuantity < kitchenDoneQuantity),
    'floor' =>
      floorServedQuantity <
          (isFloorDirect ? orderedQuantity : trayDispatchedQuantity),
    _ => false,
  };

  bool isRevertibleAt(String stationType) => switch (stationType) {
    'kitchen' => !isFloorDirect && kitchenDoneQuantity > trayReceivedQuantity,
    'tray' =>
      !isFloorDirect &&
          trayDispatchedQuantity > floorServedQuantity &&
          trayReceivedQuantity > 0,
    'floor' => floorServedQuantity > 0,
    _ => false,
  };

  bool isCompletedAt(String stationType) => switch (stationType) {
    'kitchen' => !isFloorDirect && kitchenDoneQuantity >= orderedQuantity,
    'tray' =>
      !isFloorDirect &&
          trayReceivedQuantity >= orderedQuantity &&
          trayDispatchedQuantity >= orderedQuantity,
    'floor' => floorServedQuantity >= orderedQuantity,
    _ => false,
  };

  bool isDisplayCompletedAt(String stationType) => switch (stationType) {
    'kitchen' => !isFloorDirect && kitchenDoneQuantity >= orderedQuantity,
    'tray' =>
      !isFloorDirect &&
          kitchenDoneQuantity > 0 &&
          trayReceivedQuantity >= kitchenDoneQuantity &&
          trayDispatchedQuantity >= kitchenDoneQuantity,
    'floor' => switch (isFloorDirect
        ? orderedQuantity
        : trayDispatchedQuantity) {
      final limit when limit > 0 => floorServedQuantity >= limit,
      _ => false,
    },
    _ => false,
  };

  bool isReadyFromPreviousStageAt(String stationType) => switch (stationType) {
    'tray' => !isFloorDirect && kitchenDoneQuantity > trayDispatchedQuantity,
    'floor' => !isFloorDirect && trayDispatchedQuantity > floorServedQuantity,
    _ => false,
  };

  int displayPriorityAt(String stationType) {
    if (isReadyFromPreviousStageAt(stationType)) return 0;
    if (isDisplayCompletedAt(stationType)) return 2;
    return 1;
  }

  String localizedName(String languageCode) => switch (languageCode) {
    'vi' => nameVi.trim().isEmpty ? 'Món' : nameVi,
    'en' => nameEn.trim().isEmpty ? 'Item' : nameEn,
    _ => nameKo.trim().isEmpty ? '메뉴' : nameKo,
  };

  int quantityForStage(String stage) => switch (stage) {
    'kitchen_done' => kitchenDoneQuantity,
    'tray_received' => trayReceivedQuantity,
    'tray_dispatched' => trayDispatchedQuantity,
    'floor_served' => floorServedQuantity,
    _ => 0,
  };

  EmergencyFulfillmentItem withStage(String stage, int quantity) =>
      EmergencyFulfillmentItem(
        id: id,
        orderItemId: orderItemId,
        nameKo: nameKo,
        nameVi: nameVi,
        nameEn: nameEn,
        orderedQuantity: orderedQuantity,
        kitchenDoneQuantity: stage == 'kitchen_done'
            ? quantity
            : kitchenDoneQuantity,
        trayReceivedQuantity: stage == 'tray_received'
            ? quantity
            : trayReceivedQuantity,
        trayDispatchedQuantity: stage == 'tray_dispatched'
            ? quantity
            : trayDispatchedQuantity,
        floorServedQuantity: stage == 'floor_served'
            ? quantity
            : floorServedQuantity,
        needsReview: needsReview,
        fulfillmentRoute: fulfillmentRoute,
        lineKey: lineKey,
        sourceKind: sourceKind,
        comboComponents: comboComponents,
      );

  factory EmergencyFulfillmentItem.fromJson(Map<String, dynamic> json) {
    final rawComponents = json['combo_components'];
    return EmergencyFulfillmentItem(
      id: json['id']?.toString() ?? '',
      orderItemId: json['order_item_id']?.toString() ?? '',
      nameKo: json['name_ko']?.toString() ?? '메뉴',
      nameVi: json['name_vi']?.toString() ?? 'Món',
      nameEn: json['name_en']?.toString() ?? 'Item',
      orderedQuantity: _asInt(json['ordered_quantity']),
      kitchenDoneQuantity: _asInt(json['kitchen_done_quantity']),
      trayReceivedQuantity: _asInt(json['tray_received_quantity']),
      trayDispatchedQuantity: _asInt(json['tray_dispatched_quantity']),
      floorServedQuantity: _asInt(json['floor_served_quantity']),
      needsReview: json['needs_review'] == true,
      fulfillmentRoute:
          json['fulfillment_route']?.toString() ?? 'kitchen_tray_floor',
      lineKey: json['line_key']?.toString() ?? 'base',
      sourceKind: json['source_kind']?.toString() ?? 'order_item',
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

class EmergencyFulfillmentOrder {
  const EmergencyFulfillmentOrder({
    required this.queueId,
    required this.orderId,
    required this.queueNo,
    required this.tableNumber,
    required this.floorLabel,
    required this.createdAt,
    required this.items,
    this.lastActionId,
    this.lastActionAt,
    this.stationStartedAt,
    this.stationCompletedAt,
  });

  final String queueId;
  final String orderId;
  final int queueNo;
  final String tableNumber;
  final String floorLabel;
  final DateTime createdAt;
  final List<EmergencyFulfillmentItem> items;
  final String? lastActionId;
  final DateTime? lastActionAt;
  final DateTime? stationStartedAt;
  final DateTime? stationCompletedAt;

  bool hasActionableQuantity(String stationType) =>
      items.any((item) => item.isActionableAt(stationType));

  List<EmergencyFulfillmentItem> visibleItemsAt(String stationType) {
    final visible = stationType == 'floor'
        ? items
        : items.where((item) => !item.isFloorDirect);
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
    final relevant = stationType == 'floor'
        ? items
        : items.where((item) => !item.isFloorDirect).toList(growable: false);
    return relevant.isNotEmpty &&
        relevant.every((item) => item.isCompletedAt(stationType));
  }

  bool isRecentlyCompleteAt(String stationType) =>
      isCompleteAt(stationType) ||
      (lastActionId != null && !hasActionableQuantity(stationType));

  Duration stationElapsedAt(DateTime now, String stationType) {
    final startedAt =
        stationStartedAt ?? (stationType == 'kitchen' ? createdAt : null);
    if (startedAt == null) return Duration.zero;
    final completedAt = isRecentlyCompleteAt(stationType)
        ? stationCompletedAt ?? lastActionAt
        : null;
    return (completedAt ?? now).difference(startedAt);
  }

  List<EmergencyFulfillmentDisplayItem> displayItemsAt(String stationType) {
    final directByLineKey = <String, EmergencyFulfillmentItem>{
      for (final item in items)
        if (item.sourceKind == 'combo_component') item.lineKey: item,
    };
    final referencedDirectIds = <String>{};
    for (final item in items) {
      for (final component in item.comboComponents) {
        if (!component.isFloorDirect || component.menuItemId.isEmpty) continue;
        final direct = directByLineKey['combo:${component.menuItemId}'];
        if (direct != null) referencedDirectIds.add(direct.id);
      }
    }

    final result = <EmergencyFulfillmentDisplayItem>[];
    for (final item in items) {
      if (referencedDirectIds.contains(item.id)) continue;
      if (item.isFloorDirect && stationType != 'floor') continue;
      if (item.comboComponents.isEmpty) {
        result.add(
          EmergencyFulfillmentDisplayItem(
            id: item.id,
            nameKo: item.nameKo,
            nameVi: item.nameVi,
            nameEn: item.nameEn,
            quantity: item.orderedQuantity,
            completed: item.isDisplayCompletedAt(stationType),
            readyFromPreviousStage: item.isReadyFromPreviousStageAt(
              stationType,
            ),
            readOnly: false,
          ),
        );
        continue;
      }

      for (var index = 0; index < item.comboComponents.length; index += 1) {
        final component = item.comboComponents[index];
        if (component.isFloorDirect && stationType != 'floor') continue;
        final direct = component.menuItemId.isEmpty
            ? null
            : directByLineKey['combo:${component.menuItemId}'];
        final statusItem = direct ?? item;
        result.add(
          EmergencyFulfillmentDisplayItem(
            id: '${item.id}:combo:${component.menuItemId.isEmpty ? index : component.menuItemId}',
            nameKo: component.nameKo,
            nameVi: component.nameVi,
            nameEn: component.nameEn,
            quantity: component.displayQuantity(item.orderedQuantity),
            completed: statusItem.isDisplayCompletedAt(stationType),
            readyFromPreviousStage: statusItem.isReadyFromPreviousStageAt(
              stationType,
            ),
            readOnly: false,
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

  EmergencyFulfillmentOrder copyWith({
    List<EmergencyFulfillmentItem>? items,
    String? lastActionId,
    DateTime? lastActionAt,
    DateTime? stationStartedAt,
    DateTime? stationCompletedAt,
    bool clearLastAction = false,
    bool clearStationCompletedAt = false,
  }) => EmergencyFulfillmentOrder(
    queueId: queueId,
    orderId: orderId,
    queueNo: queueNo,
    tableNumber: tableNumber,
    floorLabel: floorLabel,
    createdAt: createdAt,
    items: items ?? this.items,
    lastActionId: clearLastAction ? null : (lastActionId ?? this.lastActionId),
    lastActionAt: clearLastAction ? null : (lastActionAt ?? this.lastActionAt),
    stationStartedAt: stationStartedAt ?? this.stationStartedAt,
    stationCompletedAt: clearLastAction || clearStationCompletedAt
        ? null
        : (stationCompletedAt ?? this.stationCompletedAt),
  );

  bool isCompleteForStage(String stage) =>
      items.isNotEmpty &&
      items.every(
        (item) => stage == 'floor_served'
            ? item.floorServedQuantity >= item.orderedQuantity
            : item.isFloorDirect ||
                  item.quantityForStage(stage) >= item.orderedQuantity,
      );

  factory EmergencyFulfillmentOrder.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return EmergencyFulfillmentOrder(
      queueId: json['queue_id']?.toString() ?? '',
      orderId: json['order_id']?.toString() ?? '',
      queueNo: _asInt(json['queue_no']),
      tableNumber: json['table_number']?.toString() ?? '-',
      floorLabel: json['floor_label']?.toString() ?? '1F',
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

class EmergencyFulfillmentState {
  const EmergencyFulfillmentState({
    this.assigned = false,
    this.active = false,
    this.isLoading = false,
    this.restaurantId,
    this.sessionId,
    this.stationType,
    this.floorLabel,
    this.fulfillmentMode = FulfillmentMode.paperless,
    this.orders = const [],
    this.completedOrders = const [],
    this.pendingOutboxCount = 0,
    this.pendingQueueIds = const {},
    this.error,
  });

  final bool assigned;
  final bool active;
  final bool isLoading;
  final String? restaurantId;
  final String? sessionId;
  final String? stationType;
  final String? floorLabel;
  final FulfillmentMode fulfillmentMode;
  final List<EmergencyFulfillmentOrder> orders;
  final List<EmergencyFulfillmentOrder> completedOrders;
  final int pendingOutboxCount;
  final Set<String> pendingQueueIds;
  final String? error;

  bool get isDraining => active && !fulfillmentMode.isPaperless;

  EmergencyFulfillmentState copyWith({
    bool? assigned,
    bool? active,
    bool? isLoading,
    String? restaurantId,
    String? sessionId,
    String? stationType,
    String? floorLabel,
    FulfillmentMode? fulfillmentMode,
    List<EmergencyFulfillmentOrder>? orders,
    List<EmergencyFulfillmentOrder>? completedOrders,
    int? pendingOutboxCount,
    Set<String>? pendingQueueIds,
    String? error,
    bool clearError = false,
  }) => EmergencyFulfillmentState(
    assigned: assigned ?? this.assigned,
    active: active ?? this.active,
    isLoading: isLoading ?? this.isLoading,
    restaurantId: restaurantId ?? this.restaurantId,
    sessionId: sessionId ?? this.sessionId,
    stationType: stationType ?? this.stationType,
    floorLabel: floorLabel ?? this.floorLabel,
    fulfillmentMode: fulfillmentMode ?? this.fulfillmentMode,
    orders: orders ?? this.orders,
    completedOrders: completedOrders ?? this.completedOrders,
    pendingOutboxCount: pendingOutboxCount ?? this.pendingOutboxCount,
    pendingQueueIds: pendingQueueIds ?? this.pendingQueueIds,
    error: clearError ? null : (error ?? this.error),
  );

  factory EmergencyFulfillmentState.fromJson(Map<String, dynamic> json) {
    final rawOrders = json['orders'];
    final rawCompletedOrders = json['completed_orders'];
    return EmergencyFulfillmentState(
      assigned: json['assigned'] == true,
      active: json['active'] == true,
      restaurantId: json['restaurant_id']?.toString(),
      sessionId: json['session_id']?.toString(),
      stationType: json['station_type']?.toString(),
      floorLabel: json['floor_label']?.toString(),
      fulfillmentMode: FulfillmentMode.fromValue(
        json['fulfillment_mode'] ?? 'paperless',
      ),
      orders: rawOrders is List
          ? rawOrders
                .whereType<Map>()
                .map(
                  (order) => EmergencyFulfillmentOrder.fromJson(
                    Map<String, dynamic>.from(order),
                  ),
                )
                .toList(growable: false)
          : const [],
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
    );
  }
}

class EmergencyFulfillmentNotifier
    extends StateNotifier<EmergencyFulfillmentState> {
  EmergencyFulfillmentNotifier() : super(const EmergencyFulfillmentState());

  static const _uuid = Uuid();
  static const _handoffRefreshInterval = Duration(seconds: 1);
  RealtimeChannel? _channel;
  Timer? _pollTimer;
  bool _refreshing = false;
  bool _refreshRequested = false;
  bool _flushing = false;
  int _realtimeRevision = 0;

  Future<void> load({bool showLoading = true}) async {
    if (_refreshing) {
      _refreshRequested = true;
      return;
    }
    _refreshing = true;
    final refreshRevision = _realtimeRevision;
    if (showLoading) state = state.copyWith(isLoading: true, clearError: true);
    try {
      final outboxError = await _flushOutbox();
      final raw = await supabase.rpc('get_emergency_station_snapshot');
      final json = raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{};
      final storeId = json['restaurant_id']?.toString();
      final stationData = await Future.wait([
        _optionalRpc('get_emergency_station_today_completed'),
        _optionalRpc('get_emergency_station_timings'),
      ]);
      final completed = stationData[0];
      json['completed_orders'] = completed is List ? completed : const [];
      _mergeStationTimings(json, stationData[1]);
      if (storeId != null && storeId.isNotEmpty) {
        try {
          json['fulfillment_mode'] = await supabase.rpc(
            'get_store_fulfillment_mode',
            params: {'p_store_id': storeId},
          );
        } catch (_) {
          // Compatibility with the pre-mode migration during a staged rollout.
        }
      }
      final next = EmergencyFulfillmentState.fromJson(json);
      final pendingRecords = await EmergencyWebBridge.readOutbox();
      if (refreshRevision != _realtimeRevision) {
        _refreshRequested = true;
        return;
      }
      state = next.copyWith(
        isLoading: false,
        pendingOutboxCount: pendingRecords.length,
        pendingQueueIds: _pendingQueueIds(pendingRecords),
        error: outboxError,
        clearError: outboxError == null,
      );
      await _subscribe(next.restaurantId);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'EMERGENCY_SNAPSHOT_FAILED: $error',
      );
    } finally {
      _refreshing = false;
      if (_refreshRequested && mounted) {
        _refreshRequested = false;
        unawaited(load(showLoading: false));
      }
    }
  }

  Future<dynamic> _optionalRpc(String functionName) async {
    try {
      return await supabase.rpc(functionName);
    } catch (_) {
      // Compatibility while additive station RPCs roll out.
      return null;
    }
  }

  Future<void> _subscribe(String? storeId) async {
    if (storeId == null || storeId.isEmpty || _channel != null) {
      _startPolling();
      return;
    }
    void refresh(PostgresChangePayload _) => _requestRealtimeRefresh();
    _channel = supabase
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
          callback: _applyRealtimeItemChange,
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
        .subscribe();
    _startPolling();
  }

  void _startPolling() {
    _pollTimer ??= Timer.periodic(_handoffRefreshInterval, (_) {
      if (!_refreshing) unawaited(load(showLoading: false));
    });
  }

  void _requestRealtimeRefresh() {
    _realtimeRevision += 1;
    unawaited(load(showLoading: false));
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
    final nextOrders = state.orders
        .map((order) {
          var orderChanged = false;
          final nextItems = order.items
              .map((item) {
                if (item.id != itemId) return item;
                found = true;
                orderChanged = true;
                return item
                    .withStage(
                      'kitchen_done',
                      _asInt(row['kitchen_done_quantity']),
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
                    );
              })
              .toList(growable: false);
          return orderChanged ? order.copyWith(items: nextItems) : order;
        })
        .toList(growable: false);
    if (!found) return false;

    _realtimeRevision += 1;
    state = state.copyWith(orders: nextOrders, clearError: true);
    return true;
  }

  @visibleForTesting
  static Duration get handoffRefreshInterval => _handoffRefreshInterval;

  @visibleForTesting
  bool applyRealtimeItemRowForTesting(Map<String, dynamic> row) =>
      _applyRealtimeItemRow(row);

  Future<void> recordProgress({
    required String itemId,
    required String stage,
    int delta = 1,
  }) async {
    final floorDirect = state.orders
        .expand((order) => order.items)
        .any((item) => item.id == itemId && item.isFloorDirect);
    final eventId = _uuid.v4();
    final payload = <String, dynamic>{
      'event_id': eventId,
      'item_id': itemId,
      'stage': stage,
      'delta': delta,
      'floor_direct': floorDirect,
    };
    final previous = state;
    _applyOptimistic(itemId: itemId, stage: stage, delta: delta);
    try {
      await _sendProgress(payload);
      await load(showLoading: false);
    } catch (error) {
      if (error is PostgrestException) {
        state = previous.copyWith(error: error.message);
        return;
      }
      try {
        await EmergencyWebBridge.putOutbox(eventId, jsonEncode(payload));
        state = state.copyWith(
          pendingOutboxCount: state.pendingOutboxCount + 1,
          error: 'EMERGENCY_PROGRESS_QUEUED',
        );
      } catch (_) {
        state = previous.copyWith(error: 'EMERGENCY_PROGRESS_FAILED: $error');
      }
    }
  }

  Future<bool> completeOrder({required String queueId}) async {
    final actionId = _uuid.v4();
    final payload = <String, dynamic>{
      'kind': 'complete_order',
      'queue_id': queueId,
      'action_id': actionId,
    };
    final previous = state;
    _applyOptimisticOrderCompletion(queueId: queueId, actionId: actionId);
    try {
      await _sendOutboxPayload(payload);
      await load(showLoading: false);
      return true;
    } catch (error) {
      if (error is PostgrestException) {
        state = previous.copyWith(error: error.message);
        return false;
      }
      try {
        await EmergencyWebBridge.putOutbox(actionId, jsonEncode(payload));
        state = state.copyWith(
          pendingOutboxCount: state.pendingOutboxCount + 1,
          pendingQueueIds: {...state.pendingQueueIds, queueId},
          error: 'EMERGENCY_ORDER_ACTION_QUEUED',
        );
        return true;
      } catch (_) {
        state = previous.copyWith(error: 'EMERGENCY_ORDER_ACTION_FAILED');
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
      'kind': 'revert_order',
      'queue_id': queueId,
      'action_id': actionId,
      'revert_id': revertId,
    };
    try {
      await _sendOutboxPayload(payload);
      await load(showLoading: false);
      return true;
    } catch (error) {
      if (error is PostgrestException) {
        state = state.copyWith(error: error.message);
        return false;
      }
      try {
        await EmergencyWebBridge.putOutbox(revertId, jsonEncode(payload));
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

  void _applyOptimistic({
    required String itemId,
    required String stage,
    required int delta,
  }) {
    final actionAt = DateTime.now().toUtc();
    state = state.copyWith(
      orders: state.orders
          .map((order) {
            final nextOrder = order.copyWith(
              items: order.items
                  .map((item) {
                    if (item.id != itemId) return item;
                    final next = item.quantityForStage(stage) + delta;
                    return item.withStage(
                      stage,
                      next.clamp(0, item.orderedQuantity),
                    );
                  })
                  .toList(growable: false),
            );
            return nextOrder.copyWith(
              stationCompletedAt: nextOrder.isCompleteForStage(stage)
                  ? actionAt
                  : null,
              clearStationCompletedAt: delta < 0,
            );
          })
          .toList(growable: false),
      clearError: true,
    );
  }

  Future<void> _sendProgress(Map<String, dynamic> payload) async {
    if (payload['floor_direct'] == true) {
      await supabase.rpc(
        'emergency_record_floor_direct_progress',
        params: {
          'p_floor_direct_item_id': payload['item_id'],
          'p_delta': payload['delta'],
          'p_event_id': payload['event_id'],
        },
      );
      return;
    }
    await supabase.rpc(
      'emergency_record_progress',
      params: {
        'p_fulfillment_item_id': payload['item_id'],
        'p_stage': payload['stage'],
        'p_delta': payload['delta'],
        'p_event_id': payload['event_id'],
      },
    );
  }

  Future<void> _sendOutboxPayload(Map<String, dynamic> payload) async {
    // The route-aware wrappers delegate food work to the legacy
    // 'emergency_complete_order_stage' / 'emergency_revert_order_action'
    // contracts, then atomically include floor-direct beverage lines.
    switch (payload['kind']) {
      case 'complete_order':
        await supabase.rpc(
          'emergency_complete_route_order_stage',
          params: {
            'p_queue_id': payload['queue_id'],
            'p_action_id': payload['action_id'],
          },
        );
      case 'revert_order':
        await supabase.rpc(
          'emergency_revert_route_order_action',
          params: {
            'p_queue_id': payload['queue_id'],
            'p_action_id': payload['action_id'],
            'p_revert_id': payload['revert_id'],
          },
        );
      default:
        await _sendProgress(payload);
    }
  }

  void _applyOptimisticOrderCompletion({
    required String queueId,
    required String actionId,
  }) {
    final stationType = state.stationType;
    state = state.copyWith(
      orders: state.orders
          .map((order) {
            if (order.queueId != queueId) return order;
            return order.copyWith(
              lastActionId: actionId,
              lastActionAt: DateTime.now().toUtc(),
              stationCompletedAt: DateTime.now().toUtc(),
              items: order.items
                  .map((item) {
                    if (item.isFloorDirect && stationType != 'floor') {
                      return item;
                    }
                    return switch (stationType) {
                      'kitchen' => item.withStage(
                        'kitchen_done',
                        item.orderedQuantity,
                      ),
                      'tray' =>
                        item
                            .withStage(
                              'tray_received',
                              item.kitchenDoneQuantity,
                            )
                            .withStage(
                              'tray_dispatched',
                              item.kitchenDoneQuantity,
                            ),
                      'floor' => item.withStage(
                        'floor_served',
                        item.isFloorDirect
                            ? item.orderedQuantity
                            : item.trayDispatchedQuantity,
                      ),
                      _ => item,
                    };
                  })
                  .toList(growable: false),
            );
          })
          .toList(growable: false),
      clearError: true,
    );
  }

  Future<String?> _flushOutbox() async {
    if (_flushing) return null;
    _flushing = true;
    String? rejectedError;
    try {
      final records = await EmergencyWebBridge.readOutbox();
      for (final record in records) {
        try {
          final decoded = jsonDecode(record.payload);
          if (decoded is! Map) {
            await EmergencyWebBridge.deleteOutbox(record.id);
            continue;
          }
          await _sendOutboxPayload(Map<String, dynamic>.from(decoded));
          await EmergencyWebBridge.deleteOutbox(record.id);
        } on PostgrestException catch (error) {
          // A server-side contract rejection will not succeed on retry. Remove
          // it so one invalid undo cannot block later offline actions forever.
          await EmergencyWebBridge.deleteOutbox(record.id);
          rejectedError = error.message;
        } catch (_) {
          // Preserve ordering and retry the first unavailable event later.
          break;
        }
      }
    } finally {
      _flushing = false;
    }
    return rejectedError;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    unawaited(_channel?.unsubscribe());
    super.dispose();
  }
}

Set<String> _pendingQueueIds(List<EmergencyOutboxRecord> records) => records
    .map((record) {
      try {
        final decoded = jsonDecode(record.payload);
        return decoded is Map ? decoded['queue_id']?.toString() : null;
      } catch (_) {
        return null;
      }
    })
    .whereType<String>()
    .where((id) => id.isNotEmpty)
    .toSet();

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
