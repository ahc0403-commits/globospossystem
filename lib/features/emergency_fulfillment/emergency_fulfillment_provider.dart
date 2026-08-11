import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../core/models/fulfillment_mode.dart';
import '../../core/services/emergency_web_bridge.dart';
import '../../core/utils/live_sync_scope.dart';
import '../../main.dart';

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
      );

  factory EmergencyFulfillmentItem.fromJson(Map<String, dynamic> json) =>
      EmergencyFulfillmentItem(
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
      );
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

  bool hasActionableQuantity(String stationType) => items.any(
    (item) => switch (stationType) {
      'kitchen' => item.kitchenDoneQuantity < item.orderedQuantity,
      'tray' =>
        item.trayReceivedQuantity < item.kitchenDoneQuantity ||
            item.trayDispatchedQuantity < item.kitchenDoneQuantity,
      'floor' => item.floorServedQuantity < item.trayDispatchedQuantity,
      _ => false,
    },
  );

  EmergencyFulfillmentOrder copyWith({
    List<EmergencyFulfillmentItem>? items,
    String? lastActionId,
    DateTime? lastActionAt,
    bool clearLastAction = false,
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
  );

  bool isCompleteForStage(String stage) =>
      items.isNotEmpty &&
      items.every(
        (item) => item.quantityForStage(stage) >= item.orderedQuantity,
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
    pendingOutboxCount: pendingOutboxCount ?? this.pendingOutboxCount,
    pendingQueueIds: pendingQueueIds ?? this.pendingQueueIds,
    error: clearError ? null : (error ?? this.error),
  );

  factory EmergencyFulfillmentState.fromJson(Map<String, dynamic> json) {
    final rawOrders = json['orders'];
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
    );
  }
}

class EmergencyFulfillmentNotifier
    extends StateNotifier<EmergencyFulfillmentState> {
  EmergencyFulfillmentNotifier() : super(const EmergencyFulfillmentState());

  static const _uuid = Uuid();
  RealtimeChannel? _channel;
  Timer? _pollTimer;
  bool _refreshing = false;
  bool _flushing = false;

  Future<void> load({bool showLoading = true}) async {
    if (_refreshing) return;
    _refreshing = true;
    if (showLoading) state = state.copyWith(isLoading: true, clearError: true);
    try {
      final outboxError = await _flushOutbox();
      final raw = await supabase.rpc('get_emergency_station_snapshot');
      final json = raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{};
      final storeId = json['restaurant_id']?.toString();
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
    }
  }

  Future<void> _subscribe(String? storeId) async {
    if (storeId == null || storeId.isEmpty || _channel != null) {
      _startPolling();
      return;
    }
    void refresh(PostgresChangePayload _) =>
        unawaited(load(showLoading: false));
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
          callback: refresh,
        )
        .subscribe();
    _startPolling();
  }

  void _startPolling() {
    _pollTimer ??= Timer.periodic(
      const Duration(seconds: 10),
      (_) => unawaited(load(showLoading: false)),
    );
  }

  Future<void> recordProgress({
    required String itemId,
    required String stage,
    int delta = 1,
  }) async {
    final eventId = _uuid.v4();
    final payload = <String, dynamic>{
      'event_id': eventId,
      'item_id': itemId,
      'stage': stage,
      'delta': delta,
    };
    final previous = state;
    _applyOptimistic(itemId: itemId, stage: stage, delta: delta);
    try {
      await _sendProgress(payload);
      await load(showLoading: false);
    } catch (error) {
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
    state = state.copyWith(
      orders: state.orders
          .map((order) {
            return EmergencyFulfillmentOrder(
              queueId: order.queueId,
              orderId: order.orderId,
              queueNo: order.queueNo,
              tableNumber: order.tableNumber,
              floorLabel: order.floorLabel,
              createdAt: order.createdAt,
              lastActionId: order.lastActionId,
              lastActionAt: order.lastActionAt,
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
          })
          .toList(growable: false),
      clearError: true,
    );
  }

  Future<void> _sendProgress(Map<String, dynamic> payload) async {
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
    switch (payload['kind']) {
      case 'complete_order':
        await supabase.rpc(
          'emergency_complete_order_stage',
          params: {
            'p_queue_id': payload['queue_id'],
            'p_action_id': payload['action_id'],
          },
        );
      case 'revert_order':
        await supabase.rpc(
          'emergency_revert_order_action',
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
              items: order.items
                  .map((item) {
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
                        item.trayDispatchedQuantity,
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
