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
    required this.createdAt,
    this.isSupplemental = false,
  });

  final String itemId;
  final String label;
  final int quantity;
  final String status;
  final DateTime createdAt;
  final bool isSupplemental;

  KitchenItem copyWith({
    String? itemId,
    String? label,
    int? quantity,
    String? status,
    DateTime? createdAt,
    bool? isSupplemental,
  }) {
    return KitchenItem(
      itemId: itemId ?? this.itemId,
      label: label ?? this.label,
      quantity: quantity ?? this.quantity,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      isSupplemental: isSupplemental ?? this.isSupplemental,
    );
  }

  factory KitchenItem.fromJson(Map<String, dynamic> json) {
    final quantityRaw = json['quantity'];
    final createdAtRaw = json['created_at']?.toString();
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
      createdAt: createdAtRaw != null
          ? DateTime.tryParse(createdAtRaw) ?? DateTime.now().toUtc()
          : DateTime.now().toUtc(),
    );
  }
}

class KitchenOrder {
  const KitchenOrder({
    required this.orderId,
    required this.tableNumber,
    required this.orderPurpose,
    required this.orderSource,
    required this.createdAt,
    required this.items,
  });

  final String orderId;
  final String tableNumber;
  final String orderPurpose;
  final String orderSource;
  final DateTime createdAt;
  final List<KitchenItem> items;

  bool get isStaffMeal => orderPurpose == 'staff_meal';
  bool get isQrOrder => orderSource == 'qr';

  KitchenOrder copyWith({
    String? orderId,
    String? tableNumber,
    String? orderPurpose,
    String? orderSource,
    DateTime? createdAt,
    List<KitchenItem>? items,
  }) {
    return KitchenOrder(
      orderId: orderId ?? this.orderId,
      tableNumber: tableNumber ?? this.tableNumber,
      orderPurpose: orderPurpose ?? this.orderPurpose,
      orderSource: orderSource ?? this.orderSource,
      createdAt: createdAt ?? this.createdAt,
      items: items ?? this.items,
    );
  }
}

class KitchenState {
  const KitchenState({
    this.orders = const [],
    this.completedOrders = const [],
    this.isLoading = false,
    this.error,
  });

  final List<KitchenOrder> orders;
  final List<KitchenOrder> completedOrders;
  final bool isLoading;
  final String? error;

  KitchenState copyWith({
    List<KitchenOrder>? orders,
    List<KitchenOrder>? completedOrders,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return KitchenState(
      orders: orders ?? this.orders,
      completedOrders: completedOrders ?? this.completedOrders,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class FailedPrintJob {
  const FailedPrintJob({
    required this.id,
    required this.copyType,
    required this.batchNo,
    required this.tableNumber,
    required this.floorLabel,
    required this.status,
    required this.updatedAt,
    this.lastError,
  });

  final String id;
  final String copyType;
  final int batchNo;
  final String tableNumber;
  final String floorLabel;
  final String status;
  final DateTime updatedAt;
  final String? lastError;

  factory FailedPrintJob.fromJson(Map<String, dynamic> json) {
    final payloadRaw = json['payload'];
    final payload = payloadRaw is Map
        ? Map<String, dynamic>.from(payloadRaw)
        : <String, dynamic>{};
    final batchRaw = json['batch_no'];
    final updatedAtRaw = json['updated_at']?.toString();

    return FailedPrintJob(
      id: json['id']?.toString() ?? '',
      copyType: json['copy_type']?.toString() ?? 'kitchen',
      batchNo: switch (batchRaw) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 1,
        _ => 1,
      },
      tableNumber: payload['table_number']?.toString() ?? '-',
      floorLabel: payload['floor_label']?.toString() ?? '-',
      status: json['status']?.toString() ?? 'failed',
      updatedAt: updatedAtRaw == null
          ? DateTime.now().toUtc()
          : DateTime.tryParse(updatedAtRaw) ?? DateTime.now().toUtc(),
      lastError: json['last_error']?.toString(),
    );
  }
}

class KitchenNotifier extends StateNotifier<KitchenState> {
  KitchenNotifier() : super(const KitchenState());

  static const _autoRefreshInterval = Duration(seconds: 2);
  static const _fallbackPollInterval = Duration(seconds: 15);

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
            'id, created_at, status, order_purpose, order_source, tables(table_number), order_items(id, created_at, label, quantity, status, menu_items(name))',
          )
          .eq('restaurant_id', storeId)
          .inFilter('status', ['pending', 'confirmed', 'serving', 'completed'])
          .order('created_at', ascending: true)
          .order('created_at', referencedTable: 'order_items', ascending: true)
          .order('id', referencedTable: 'order_items', ascending: true);

      // Lane eligibility is an ORDER-status fact
      // (ORDER_LIFECYCLE_STATE_CONTRACT: kitchen never shows completed).
      // Item-status-only partitioning left paid orders with never-served
      // items in the active lanes forever.
      final statusByOrderId = <String, String>{
        for (final row in response)
          row['id'].toString(): row['status']?.toString() ?? 'pending',
      };

      final allOrders = response.map<KitchenOrder>((row) {
        final data = Map<String, dynamic>.from(row);
        final orderItems = data['order_items'];
        final itemRows = orderItems is List
            ? orderItems
                  .map((item) => Map<String, dynamic>.from(item as Map))
                  .toList()
            : <Map<String, dynamic>>[];
        itemRows.sort(_compareOrderItemRowsByCreatedAt);
        final items = itemRows.map<KitchenItem>(KitchenItem.fromJson).toList();

        final tableData = data['tables'];
        String tableNumber = '-';
        if (tableData is Map<String, dynamic>) {
          tableNumber = tableData['table_number']?.toString() ?? '-';
        } else if (data['order_purpose']?.toString() == 'staff_meal') {
          tableNumber = 'STAFF';
        }

        final createdAtRaw = data['created_at']?.toString();
        final createdAt = createdAtRaw != null
            ? DateTime.tryParse(createdAtRaw) ?? DateTime.now().toUtc()
            : DateTime.now().toUtc();
        final firstItemCreatedAt = items.isEmpty
            ? createdAt
            : items
                  .map((item) => item.createdAt.toUtc())
                  .reduce((a, b) => a.isBefore(b) ? a : b);
        final itemsWithSupplementFlags = items
            .map(
              (item) => item.copyWith(
                isSupplemental:
                    item.createdAt.toUtc().difference(firstItemCreatedAt) >
                    const Duration(seconds: 10),
              ),
            )
            .toList();

        return KitchenOrder(
          orderId: data['id'].toString(),
          tableNumber: tableNumber,
          orderPurpose: data['order_purpose']?.toString() ?? 'customer',
          orderSource: data['order_source']?.toString() ?? 'staff',
          createdAt: createdAt,
          items: itemsWithSupplementFlags,
        );
      }).toList();
      final orders = allOrders
          .where((order) => statusByOrderId[order.orderId] != 'completed')
          .map(
            (order) => order.copyWith(
              items: order.items
                  .where(
                    (item) =>
                        item.status != 'served' && item.status != 'cancelled',
                  )
                  .toList(),
            ),
          )
          .where((order) => order.items.isNotEmpty)
          .toList();
      final completedOrders = allOrders
          .where((order) => statusByOrderId[order.orderId] == 'completed')
          .map(
            (order) => order.copyWith(
              items: order.items
                  .where((item) => item.status != 'cancelled')
                  .toList(),
            ),
          )
          .toList()
          .reversed
          .take(12)
          .toList();

      state = state.copyWith(
        orders: orders,
        completedOrders: completedOrders,
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
    if (_realtimeConnected) {
      _pollTimer?.cancel();
      _pollTimer = null;
      return;
    }

    if (_pollTimer != null && _pollStoreId == storeId) {
      return;
    }

    _pollTimer?.cancel();
    _pollStoreId = storeId;
    _pollTimer = Timer.periodic(_fallbackPollInterval, (_) {
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

  Future<void> completeOrder(String orderId) async {
    final storeId = _restaurantId;
    if (storeId == null) {
      state = state.copyWith(
        error: 'Failed to complete kitchen order: restaurant context missing',
      );
      return;
    }

    final previous = state.orders;
    state = state.copyWith(
      orders: state.orders.where((order) => order.orderId != orderId).toList(),
      clearError: true,
    );

    try {
      await orderService.completeKitchenOrder(
        orderId: orderId,
        storeId: storeId,
      );
      await loadOrders(storeId, showLoading: false);
    } catch (error) {
      state = state.copyWith(
        orders: previous,
        error: 'Failed to complete kitchen order: $error',
      );
    }
  }

  Future<void> reprintPrintJob(String jobId) async {
    await supabase.rpc('reprint_print_job', params: {'p_job_id': jobId});
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

final failedPrintJobsProvider = FutureProvider.autoDispose
    .family<List<FailedPrintJob>, String>((ref, storeId) async {
      final rows = await supabase
          .from('print_jobs')
          .select(
            'id, copy_type, batch_no, payload, status, last_error, updated_at',
          )
          .eq('restaurant_id', storeId)
          .eq('status', 'failed')
          .order('updated_at', ascending: false)
          .limit(8);

      return rows
          .map<FailedPrintJob>(
            (row) => FailedPrintJob.fromJson(Map<String, dynamic>.from(row)),
          )
          .toList();
    });

final printStationJobsProvider = FutureProvider.autoDispose
    .family<List<FailedPrintJob>, String>((ref, storeId) async {
      final rows = await supabase
          .from('print_jobs')
          .select(
            'id, copy_type, batch_no, payload, status, last_error, updated_at',
          )
          .eq('restaurant_id', storeId)
          .inFilter('status', ['pending', 'printing', 'failed'])
          .order('updated_at', ascending: false)
          .limit(12);

      return rows
          .map<FailedPrintJob>(
            (row) => FailedPrintJob.fromJson(Map<String, dynamic>.from(row)),
          )
          .toList();
    });
