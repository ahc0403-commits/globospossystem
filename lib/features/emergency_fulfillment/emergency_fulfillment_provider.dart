import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

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
  });

  final String queueId;
  final String orderId;
  final int queueNo;
  final String tableNumber;
  final String floorLabel;
  final DateTime createdAt;
  final List<EmergencyFulfillmentItem> items;

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
    this.orders = const [],
    this.pendingOutboxCount = 0,
    this.error,
  });

  final bool assigned;
  final bool active;
  final bool isLoading;
  final String? restaurantId;
  final String? sessionId;
  final String? stationType;
  final String? floorLabel;
  final List<EmergencyFulfillmentOrder> orders;
  final int pendingOutboxCount;
  final String? error;

  EmergencyFulfillmentState copyWith({
    bool? assigned,
    bool? active,
    bool? isLoading,
    String? restaurantId,
    String? sessionId,
    String? stationType,
    String? floorLabel,
    List<EmergencyFulfillmentOrder>? orders,
    int? pendingOutboxCount,
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
    orders: orders ?? this.orders,
    pendingOutboxCount: pendingOutboxCount ?? this.pendingOutboxCount,
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
      await _flushOutbox();
      final raw = await supabase.rpc('get_emergency_station_snapshot');
      final json = raw is Map
          ? Map<String, dynamic>.from(raw)
          : <String, dynamic>{};
      final next = EmergencyFulfillmentState.fromJson(json);
      state = next.copyWith(
        isLoading: false,
        pendingOutboxCount: (await EmergencyWebBridge.readOutbox()).length,
        clearError: true,
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

  Future<void> _flushOutbox() async {
    if (_flushing) return;
    _flushing = true;
    try {
      final records = await EmergencyWebBridge.readOutbox();
      for (final record in records) {
        try {
          final decoded = jsonDecode(record.payload);
          if (decoded is! Map) continue;
          await _sendProgress(Map<String, dynamic>.from(decoded));
          await EmergencyWebBridge.deleteOutbox(record.id);
        } catch (_) {
          // Preserve ordering and retry the first unavailable event later.
          break;
        }
      }
    } finally {
      _flushing = false;
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    unawaited(_channel?.unsubscribe());
    super.dispose();
  }
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
