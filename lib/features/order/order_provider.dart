import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/order_service.dart';
import '../../main.dart';
import 'order_model.dart';

class OrderState {
  const OrderState({
    this.cart = const [],
    this.isSubmitting = false,
    this.error,
    this.activeOrder,
  });

  final List<CartItem> cart;
  final bool isSubmitting;
  final String? error;
  final Order? activeOrder;

  OrderState copyWith({
    List<CartItem>? cart,
    bool? isSubmitting,
    String? error,
    Order? activeOrder,
    bool clearError = false,
    bool clearActiveOrder = false,
  }) {
    return OrderState(
      cart: cart ?? this.cart,
      isSubmitting: isSubmitting ?? this.isSubmitting,
      error: clearError ? null : (error ?? this.error),
      activeOrder: clearActiveOrder ? null : (activeOrder ?? this.activeOrder),
    );
  }
}

class OrderNotifier extends StateNotifier<OrderState> {
  OrderNotifier() : super(const OrderState());

  RealtimeChannel? _orderItemsChannel;
  String? _subscribedOrderId;

  List<Map<String, dynamic>> _cartPayloadItems() {
    return state.cart
        .map(
          (item) => {
            'menu_item_id': item.menuItemId,
            'label': item.name,
            'unit_price': item.price,
            'quantity': item.quantity,
            'item_type': 'menu',
          },
        )
        .toList();
  }

  void addToCart(CartItem item) {
    final current = [...state.cart];
    final index = current.indexWhere(
      (cartItem) => cartItem.menuItemId == item.menuItemId,
    );

    if (index >= 0) {
      final existing = current[index];
      current[index] = existing.copyWith(
        quantity: existing.quantity + item.quantity,
      );
    } else {
      current.add(item);
    }

    state = state.copyWith(cart: current, clearError: true);
  }

  void removeFromCart(String menuItemId) {
    state = state.copyWith(
      cart: state.cart.where((item) => item.menuItemId != menuItemId).toList(),
      clearError: true,
    );
  }

  void decrementCartItem(String menuItemId) {
    final current = [...state.cart];
    final index = current.indexWhere((item) => item.menuItemId == menuItemId);
    if (index < 0) {
      return;
    }

    final existing = current[index];
    if (existing.quantity <= 1) {
      current.removeAt(index);
    } else {
      current[index] = existing.copyWith(quantity: existing.quantity - 1);
    }

    state = state.copyWith(cart: current, clearError: true);
  }

  void clearCart() {
    state = state.copyWith(cart: const [], clearError: true);
  }

  void clearSession() {
    _unsubscribeOrderItems();
    state = state.copyWith(
      cart: const [],
      clearActiveOrder: true,
      clearError: true,
      isSubmitting: false,
    );
  }

  Future<void> loadActiveOrder(String tableId, String storeId) async {
    try {
      final response = await supabase
          .from('orders')
          .select(
            'id, table_id, status, created_at, order_items(id, menu_item_id, label, unit_price, quantity, status, item_type, menu_items(name))',
          )
          .eq('table_id', tableId)
          .eq('restaurant_id', storeId)
          .not('status', 'in', '(completed,cancelled)')
          .order('created_at', ascending: false)
          .limit(1);

      final activeOrder = response.isEmpty
          ? null
          : Order.fromJson(Map<String, dynamic>.from(response.first));

      state = state.copyWith(activeOrder: activeOrder, clearError: true);

      // Subscribe to order_items changes for realtime kitchen status updates
      if (activeOrder != null) {
        await _subscribeOrderItems(activeOrder.id, tableId, storeId);
      } else {
        await _unsubscribeOrderItems();
      }
    } catch (error) {
      state = state.copyWith(error: 'Failed to load active order: $error');
    }
  }

  Future<void> _subscribeOrderItems(
    String orderId,
    String tableId,
    String storeId,
  ) async {
    if (_subscribedOrderId == orderId && _orderItemsChannel != null) {
      return;
    }

    await _unsubscribeOrderItems();
    _subscribedOrderId = orderId;

    _orderItemsChannel = supabase
        .channel('public:waiter_order_items:$orderId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'order_items',
          callback: (_) {
            if (mounted) {
              loadActiveOrder(tableId, storeId);
            }
          },
        )
        .subscribe();
  }

  Future<void> _unsubscribeOrderItems() async {
    if (_orderItemsChannel != null) {
      await _orderItemsChannel!.unsubscribe();
      _orderItemsChannel = null;
      _subscribedOrderId = null;
    }
  }

  Future<void> submitOrder(String storeId, String tableId) async {
    if (state.cart.isEmpty) {
      return;
    }

    state = state.copyWith(isSubmitting: true, clearError: true);

    try {
      await orderService.createOrder(
        storeId: storeId,
        tableId: tableId,
        items: _cartPayloadItems(),
      );

      state = state.copyWith(cart: const []);
      await loadActiveOrder(tableId, storeId);
    } catch (error) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to submit order'),
      );
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<void> addMoreItems(String orderId, String storeId) async {
    if (state.cart.isEmpty) {
      return;
    }

    final activeTableId = state.activeOrder?.tableId;
    state = state.copyWith(isSubmitting: true, clearError: true);

    try {
      await orderService.addItemsToOrder(
        orderId: orderId,
        storeId: storeId,
        items: _cartPayloadItems(),
      );

      state = state.copyWith(cart: const []);
      if (activeTableId != null) {
        await loadActiveOrder(activeTableId, storeId);
      }
    } catch (error) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to add items to order'),
      );
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<void> submitBuffetOrder(
    String storeId,
    String tableId,
    int guestCount,
  ) async {
    if (guestCount <= 0) {
      state = state.copyWith(error: 'Guest count must be at least 1.');
      return;
    }

    state = state.copyWith(isSubmitting: true, clearError: true);

    try {
      await orderService.createBuffetOrder(
        storeId: storeId,
        tableId: tableId,
        guestCount: guestCount,
        extraItems: _cartPayloadItems(),
      );

      state = state.copyWith(cart: const []);
      await loadActiveOrder(tableId, storeId);
    } catch (error) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to submit buffet order'),
      );
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<void> cancelOrder(String orderId, String storeId) async {
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await orderService.cancelOrder(
        orderId: orderId,
        storeId: storeId,
      );
      state = state.copyWith(
        isSubmitting: false,
        clearActiveOrder: true,
        cart: const [],
        clearError: true,
      );
    } on PostgrestException catch (error) {
      state = state.copyWith(
        isSubmitting: false,
        error: _mapOrderError(error, 'Failed to cancel order'),
      );
    } catch (error) {
      state = state.copyWith(
        isSubmitting: false,
        error: _mapOrderError(error, 'Failed to cancel order'),
      );
    }
  }

  Future<void> cancelOrderItem(
    String itemId,
    String storeId,
  ) async {
    final tableId = state.activeOrder?.tableId;
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await orderService.cancelOrderItem(
        itemId: itemId,
        storeId: storeId,
      );
      if (tableId != null) {
        await loadActiveOrder(tableId, storeId);
      }
    } catch (error) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to cancel item'),
      );
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<void> editOrderItemQuantity(
    String itemId,
    String storeId,
    int newQuantity,
  ) async {
    final tableId = state.activeOrder?.tableId;
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await orderService.editOrderItemQuantity(
        itemId: itemId,
        storeId: storeId,
        newQuantity: newQuantity,
      );
      if (tableId != null) {
        await loadActiveOrder(tableId, storeId);
      }
    } catch (error) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to change quantity'),
      );
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<void> transferOrderTable(
    String orderId,
    String storeId,
    String newTableId,
  ) async {
    state = state.copyWith(isSubmitting: true, clearError: true);
    try {
      await orderService.transferOrderTable(
        orderId: orderId,
        storeId: storeId,
        newTableId: newTableId,
      );
      await loadActiveOrder(newTableId, storeId);
    } catch (error) {
      state = state.copyWith(
        error: _mapOrderError(error, 'Failed to move table'),
      );
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<void> updateOrderItemStatus(
    String itemId,
    String newStatus,
    String storeId,
    String tableId,
  ) async {
    if (itemId.isEmpty) {
      return;
    }

    final previousOrder = state.activeOrder;
    if (previousOrder != null) {
      final updatedItems = previousOrder.items.map((item) {
        if (item.id != itemId) {
          return item;
        }
        return item.copyWith(status: newStatus);
      }).toList();
      state = state.copyWith(
        activeOrder: previousOrder.copyWith(items: updatedItems),
        clearError: true,
      );
    }

    try {
      await orderService.updateOrderItemStatus(
        itemId: itemId,
        storeId: storeId,
        status: newStatus,
      );
      await loadActiveOrder(tableId, storeId);
    } on PostgrestException catch (error) {
      state = state.copyWith(
        activeOrder: previousOrder,
        error: _mapOrderError(error, 'Failed to update item status'),
      );
    } catch (error) {
      state = state.copyWith(
        activeOrder: previousOrder,
        error: _mapOrderError(error, 'Failed to update item status'),
      );
    }
  }
}

final orderProvider = StateNotifierProvider<OrderNotifier, OrderState>(
  (ref) => OrderNotifier(),
);

String _mapOrderError(Object error, String fallbackPrefix) {
  if (error is PostgrestException) {
    return switch (error.message) {
      'TABLE_ALREADY_OCCUPIED' => 'The selected table is already occupied.',
      'TABLE_NOT_FOUND' => 'The selected table could not be found.',
      'ORDER_ITEMS_REQUIRED' =>
        'Add at least one item before sending the order.',
      'INVALID_ORDER_ITEM_INPUT' =>
        'One or more selected items are invalid for this order.',
      'MENU_ITEM_NOT_AVAILABLE' =>
        'One or more selected menu items are unavailable.',
      'ORDER_CREATE_FORBIDDEN' =>
        'You do not have permission to create an order for this restaurant.',
      'ORDER_MUTATION_FORBIDDEN' =>
        'You do not have permission to change this order.',
      'ORDER_NOT_FOUND' => 'The selected order could not be found.',
      'ORDER_NOT_MUTABLE' => 'This order can no longer be changed.',
      'ORDER_NOT_CANCELLABLE' =>
        'Only pending or confirmed orders can be cancelled.',
      'BUFFET_GUEST_COUNT_REQUIRED' =>
        'Buffet orders require a guest count of at least 1.',
      'OPERATION_MODE_MISMATCH' =>
        'This restaurant does not support buffet ordering for this flow.',
      'ORDER_ITEM_STATUS_FORBIDDEN' =>
        'You do not have permission to change kitchen item status.',
      'ORDER_ITEM_NOT_FOUND' => 'The selected order item could not be found.',
      'INVALID_ORDER_ITEM_STATUS_TRANSITION' =>
        'That item status transition is not allowed.',
      'ORDER_NOT_PAYABLE' => 'Completed or cancelled orders cannot be changed.',
      'ITEM_NOT_CANCELLABLE' =>
        'Only pending or preparing items can be cancelled.',
      'ITEM_NOT_EDITABLE' =>
        'Only pending items can have their quantity edited.',
      'ITEM_IS_CANCELLED' => 'This item has been cancelled.',
      'INVALID_QUANTITY' => 'Quantity must be at least 1.',
      'TRANSFER_SAME_TABLE' => 'Cannot transfer to the same table.',
      _ => '$fallbackPrefix: ${error.message}',
    };
  }
  return '$fallbackPrefix: $error';
}
