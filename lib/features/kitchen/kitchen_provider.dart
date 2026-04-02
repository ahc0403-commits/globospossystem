import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    return KitchenItem(
      itemId: json['id'].toString(),
      label: json['label']?.toString() ?? json['name']?.toString() ?? 'Item',
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

  RealtimeChannel? _ordersChannel;
  String? _restaurantId;

  Future<void> loadOrders(String restaurantId) async {
    _restaurantId = restaurantId;
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final response = await supabase
          .from('orders')
          .select(
            'id, created_at, status, tables(table_number), order_items(id, label, quantity, status)',
          )
          .eq('restaurant_id', restaurantId)
          .inFilter('status', ['pending', 'confirmed', 'serving'])
          .order('created_at', ascending: true);

      final orders = response
          .map<KitchenOrder>((row) {
            final data = Map<String, dynamic>.from(row);
            final orderItems = data['order_items'];
            final items = (orderItems is List)
                ? orderItems
                    .map<KitchenItem>(
                      (item) => KitchenItem.fromJson(Map<String, dynamic>.from(item)),
                    )
                    .where((item) => item.status != 'served')
                    .toList()
                : <KitchenItem>[];

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

      state = state.copyWith(orders: orders, isLoading: false, clearError: true);
      await subscribeRealtime(restaurantId);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load kitchen orders: $error',
      );
    }
  }

  Future<void> subscribeRealtime(String restaurantId) async {
    if (_ordersChannel != null && _restaurantId == restaurantId) {
      return;
    }

    if (_ordersChannel != null) {
      await _ordersChannel!.unsubscribe();
    }

    _restaurantId = restaurantId;
    _ordersChannel = supabase
        .channel('public:kitchen_orders:$restaurantId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'orders',
          callback: (_) => loadOrders(restaurantId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'orders',
          callback: (_) => loadOrders(restaurantId),
        )
        .subscribe();
  }

  Future<void> updateItemStatus(String itemId, String newStatus) async {
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
        .toList();

    state = state.copyWith(orders: optimisticOrders, clearError: true);

    try {
      await supabase
          .from('order_items')
          .update({'status': newStatus})
          .eq('id', itemId);
    } catch (error) {
      state = state.copyWith(
        orders: previous,
        error: 'Failed to update item status: $error',
      );
    }
  }

  @override
  void dispose() {
    _ordersChannel?.unsubscribe();
    _ordersChannel = null;
    super.dispose();
  }
}

final kitchenProvider = StateNotifierProvider<KitchenNotifier, KitchenState>(
  (ref) => KitchenNotifier(),
);
