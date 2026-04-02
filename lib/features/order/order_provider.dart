import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  void addToCart(CartItem item) {
    final current = [...state.cart];
    final index = current.indexWhere((cartItem) => cartItem.menuItemId == item.menuItemId);

    if (index >= 0) {
      final existing = current[index];
      current[index] = existing.copyWith(quantity: existing.quantity + item.quantity);
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
    state = state.copyWith(
      cart: const [],
      clearActiveOrder: true,
      clearError: true,
      isSubmitting: false,
    );
  }

  Future<void> loadActiveOrder(String tableId, String restaurantId) async {
    try {
      final response = await supabase
          .from('orders')
          .select(
            'id, table_id, status, created_at, order_items(id, menu_item_id, label, unit_price, quantity, status, item_type)',
          )
          .eq('table_id', tableId)
          .eq('restaurant_id', restaurantId)
          .not('status', 'in', '(completed,cancelled)')
          .order('created_at', ascending: false)
          .limit(1);

      final activeOrder = response.isEmpty
          ? null
          : Order.fromJson(Map<String, dynamic>.from(response.first));

      state = state.copyWith(activeOrder: activeOrder, clearError: true);
    } catch (error) {
      state = state.copyWith(error: 'Failed to load active order: $error');
    }
  }

  Future<void> submitOrder(String restaurantId, String tableId) async {
    if (state.cart.isEmpty) {
      return;
    }

    state = state.copyWith(isSubmitting: true, clearError: true);

    try {
      final payloadItems = state.cart
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

      await supabase.rpc(
        'create_order',
        params: {
          'p_restaurant_id': restaurantId,
          'p_table_id': tableId,
          'p_items': payloadItems,
        },
      );

      state = state.copyWith(cart: const []);
      await loadActiveOrder(tableId, restaurantId);
    } catch (error) {
      state = state.copyWith(error: 'Failed to submit order: $error');
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }

  Future<void> addMoreItems(String orderId, String restaurantId) async {
    if (state.cart.isEmpty) {
      return;
    }

    final activeTableId = state.activeOrder?.tableId;
    state = state.copyWith(isSubmitting: true, clearError: true);

    try {
      final payloadItems = state.cart
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

      await supabase.rpc(
        'add_items_to_order',
        params: {
          'p_order_id': orderId,
          'p_restaurant_id': restaurantId,
          'p_items': payloadItems,
        },
      );

      state = state.copyWith(cart: const []);
      if (activeTableId != null) {
        await loadActiveOrder(activeTableId, restaurantId);
      }
    } catch (error) {
      state = state.copyWith(error: 'Failed to add items to order: $error');
    } finally {
      state = state.copyWith(isSubmitting: false);
    }
  }
}

final orderProvider = StateNotifierProvider<OrderNotifier, OrderState>(
  (ref) => OrderNotifier(),
);
