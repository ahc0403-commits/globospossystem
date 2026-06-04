import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/order_service.dart';
import '../../core/utils/live_sync_scope.dart';
import '../../main.dart';

class KitchenItem {
  const KitchenItem({
    required this.itemId,
    required this.label,
    required this.quantity,
    required this.status,
  });

  final String itemId;
  final String label;
  final int quantity;
  final String status;

  KitchenItem copyWith({
    String? itemId,
    String? label,
    int? quantity,
    String? status,
  }) {
    return KitchenItem(
      itemId: itemId ?? this.itemId,
      label: label ?? this.label,
      quantity: quantity ?? this.quantity,
      status: status ?? this.status,
    );
  }

  factory KitchenItem.fromJson(Map<String, dynamic> json) {
    final quantityRaw = json['quantity'];
    final menuItemRaw = json['menu_items'];
    String? menuItemName;
    if (menuItemRaw is Map<String, dynamic>) {
      menuItemName = menuItemRaw['name']?.toString();
    }
    return KitchenItem(
      itemId: json['id'].toString(),
      label:
          json['label']?.toString() ??
          json['name']?.toString() ??
          menuItemName ??
          'Item',
      quantity: switch (quantityRaw) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 0,
        _ => 0,
      },
      status: json['status']?.toString() ?? 'pending',
    );
  }
}

class KitchenOrder {
  const KitchenOrder({
    required this.orderId,
    required this.tableNumber,
    required this.createdAt,
    required this.items,
  });

  final String orderId;
  final String tableNumber;
  final DateTime createdAt;
  final List<KitchenItem> items;

  KitchenOrder copyWith({
    String? orderId,
    String? tableNumber,
    DateTime? createdAt,
    List<KitchenItem>? items,
  }) {
    return KitchenOrder(
      orderId: orderId ?? this.orderId,
      tableNumber: tableNumber ?? this.tableNumber,
      createdAt: createdAt ?? this.createdAt,
      items: items ?? this.items,
    );
  }
}

class KitchenState {
  const KitchenState({
    this.orders = const [],
    this.isLoading = false,
    this.error,
  });

  final List<KitchenOrder> orders;
  final bool isLoading;
  final String? error;

  KitchenState copyWith({
    List<KitchenOrder>? orders,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return KitchenState(
      orders: orders ?? this.orders,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class KitchenNotifier extends StateNotifier<KitchenState> {
  KitchenNotifier() : super(const KitchenState());

  static const _autoRefreshInterval = Duration(seconds: 2);

  RealtimeChannel? _ordersChannel;
  String? _restaurantId;
  // Realtime can report subscribed while table events are still delayed or
  // filtered. Keep a lightweight safety refresh so kitchen never depends on
  // manual reload to see waiter submissions.
  Timer? _pollTimer;
  String? _pollStoreId;
  bool _realtimeConnected = false;

  Future<void> loadOrders(String storeId, {bool showLoading = true}) async {
    _restaurantId = storeId;
    if (showLoading) {
      state = state.copyWith(isLoading: true, clearError: true);
    }

    try {
      final response = await supabase
          .from('orders')
          .select(
            'id, created_at, status, tables(table_number), order_items(id, created_at, label, quantity, status, menu_items(name))',
          )
          .eq('restaurant_id', storeId)
          .inFilter('status', ['pending', 'confirmed', 'serving'])
          .order('created_at', ascending: true)
          .order('created_at', referencedTable: 'order_items', ascending: true)
          .order('id', referencedTable: 'order_items', ascending: true);

      final orders = response
          .map<KitchenOrder>((row) {
            final data = Map<String, dynamic>.from(row);
            final orderItems = data['order_items'];
            final itemRows = orderItems is List
                ? orderItems
                      .map((item) => Map<String, dynamic>.from(item as Map))
                      .toList()
                : <Map<String, dynamic>>[];
            itemRows.sort(_compareOrderItemRowsByCreatedAt);
            final items = itemRows
                .map<KitchenItem>(KitchenItem.fromJson)
                .where(
                  (item) =>
                      item.status != 'served' && item.status != 'cancelled',
                )
                .toList();

            final tableData = data['tables'];
            String tableNumber = '-';
            if (tableData is Map<String, dynamic>) {
              tableNumber = tableData['table_number']?.toString() ?? '-';
            }

            final createdAtRaw = data['created_at']?.toString();

            return KitchenOrder(
              orderId: data['id'].toString(),
              tableNumber: tableNumber,
              createdAt: createdAtRaw != null
                  ? DateTime.tryParse(createdAtRaw) ?? DateTime.now()
                  : DateTime.now(),
              items: items,
            );
          })
          .where((order) => order.items.isNotEmpty)
          .toList();

      state = state.copyWith(
        orders: orders,
        isLoading: false,
        clearError: true,
      );
      await subscribeRealtime(storeId);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load kitchen orders: $error',
      );
    }
  }

  Future<void> subscribeRealtime(String storeId) async {
    if (_ordersChannel != null && _restaurantId == storeId) {
      _ensureAutoRefresh(storeId);
      return;
    }

    if (_ordersChannel != null) {
      await _ordersChannel!.unsubscribe();
    }
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollStoreId = null;
    _realtimeConnected = false;

    _restaurantId = storeId;
    _ordersChannel = supabase
        .channel(LiveSyncScope.storeChannel('kitchen_orders', storeId))
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'orders',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshKitchenOrdersFromRealtime(storeId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'orders',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshKitchenOrdersFromRealtime(storeId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'order_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshKitchenOrdersFromRealtime(storeId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'order_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshKitchenOrdersFromRealtime(storeId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'order_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshKitchenOrdersFromRealtime(storeId),
        )
        .subscribe((status, [error]) {
          // Realtime 연결 상태 추적
          final connected = status == RealtimeSubscribeStatus.subscribed;
          if (connected != _realtimeConnected) {
            _realtimeConnected = connected;
            if (connected) {
              _ensureAutoRefresh(storeId);
            } else {
              _ensureAutoRefresh(storeId);
            }
          }
        });
    _ensureAutoRefresh(storeId);
    Future.delayed(_autoRefreshInterval, () {
      if (mounted && !_realtimeConnected && _restaurantId == storeId) {
        _ensureAutoRefresh(storeId);
      }
    });
  }

  void _refreshKitchenOrdersFromRealtime(String storeId) {
    if (!mounted) {
      return;
    }
    unawaited(loadOrders(storeId, showLoading: false));
  }

  void _ensureAutoRefresh(String storeId) {
    if (_pollTimer != null && _pollStoreId == storeId) {
      return;
    }

    _pollTimer?.cancel();
    _pollStoreId = storeId;
    _pollTimer = Timer.periodic(_autoRefreshInterval, (_) {
      if (mounted && _restaurantId == storeId) {
        unawaited(loadOrders(storeId, showLoading: false));
      }
    });
  }

  Future<void> updateItemStatus(String itemId, String newStatus) async {
    final storeId = _restaurantId;
    if (storeId == null) {
      state = state.copyWith(
        error: 'Failed to update item status: restaurant context missing',
      );
      return;
    }

    final previous = state.orders;

    final optimisticOrders = state.orders
        .map(
          (order) => order.copyWith(
            items: order.items
                .map(
                  (item) => item.itemId == itemId
                      ? item.copyWith(status: newStatus)
                      : item,
                )
                .toList(),
          ),
        )
        .where((order) {
          if (order.items.isEmpty) return false;
          final hasThisItem = order.items.any((item) => item.itemId == itemId);
          if (!hasThisItem) return true;
          final allServed = order.items.every((item) {
            if (item.itemId == itemId) {
              return newStatus == 'served';
            }
            return item.status == 'served';
          });
          return !allServed;
        })
        .toList();

    state = state.copyWith(orders: optimisticOrders, clearError: true);

    try {
      await orderService.updateOrderItemStatus(
        itemId: itemId,
        storeId: storeId,
        status: newStatus,
      );
      await loadOrders(storeId, showLoading: false);
    } catch (error) {
      state = state.copyWith(
        orders: previous,
        error: 'Failed to update item status: $error',
      );
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollStoreId = null;
    _ordersChannel?.unsubscribe();
    _ordersChannel = null;
    super.dispose();
  }
}

int _compareOrderItemRowsByCreatedAt(
  Map<String, dynamic> left,
  Map<String, dynamic> right,
) {
  final leftCreatedAt = DateTime.tryParse(left['created_at']?.toString() ?? '');
  final rightCreatedAt = DateTime.tryParse(
    right['created_at']?.toString() ?? '',
  );

  if (leftCreatedAt != null && rightCreatedAt != null) {
    final createdAtComparison = leftCreatedAt.compareTo(rightCreatedAt);
    if (createdAtComparison != 0) {
      return createdAtComparison;
    }
  } else if (leftCreatedAt != null) {
    return -1;
  } else if (rightCreatedAt != null) {
    return 1;
  }

  return (left['id']?.toString() ?? '').compareTo(
    right['id']?.toString() ?? '',
  );
}

final kitchenProvider = StateNotifierProvider<KitchenNotifier, KitchenState>(
  (ref) => KitchenNotifier(),
);
