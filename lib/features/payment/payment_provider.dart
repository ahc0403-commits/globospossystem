import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/order_service.dart';
import '../../core/services/payment_service.dart';
import '../../main.dart';
import '../order/order_model.dart';

class CashierOrder {
  const CashierOrder({
    required this.orderId,
    required this.tableNumber,
    required this.tableId,
    required this.status,
    required this.items,
    required this.totalAmount,
    required this.createdAt,
  });

  final String orderId;
  final String tableNumber;
  final String tableId;
  final String status;
  final List<OrderItem> items;
  final double totalAmount;
  final DateTime createdAt;
}

class PaymentState {
  const PaymentState({
    this.orders = const [],
    this.selectedOrder,
    this.isProcessing = false,
    this.paymentSuccess = false,
    this.error,
  });

  final List<CashierOrder> orders;
  final CashierOrder? selectedOrder;
  final bool isProcessing;
  final bool paymentSuccess;
  final String? error;

  PaymentState copyWith({
    List<CashierOrder>? orders,
    CashierOrder? selectedOrder,
    bool? isProcessing,
    bool? paymentSuccess,
    String? error,
    bool clearSelectedOrder = false,
    bool clearPaymentSuccess = false,
    bool clearError = false,
  }) {
    return PaymentState(
      orders: orders ?? this.orders,
      selectedOrder: clearSelectedOrder
          ? null
          : (selectedOrder ?? this.selectedOrder),
      isProcessing: isProcessing ?? this.isProcessing,
      paymentSuccess: clearPaymentSuccess
          ? false
          : (paymentSuccess ?? this.paymentSuccess),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class PaymentNotifier extends StateNotifier<PaymentState> {
  PaymentNotifier() : super(const PaymentState());

  RealtimeChannel? _ordersChannel;
  RealtimeChannel? _paymentsChannel;
  String? _restaurantId;

  Future<void> loadOrders(String restaurantId) async {
    _restaurantId = restaurantId;

    try {
      final response = await supabase
          .from('orders')
          .select(
            'id, table_id, status, created_at, tables(table_number), order_items(id, menu_item_id, label, unit_price, quantity, status, item_type)',
          )
          .eq('restaurant_id', restaurantId)
          .not('status', 'in', '(completed,cancelled)')
          .order('created_at', ascending: true);

      final orders = response.map<CashierOrder>((row) {
        final data = Map<String, dynamic>.from(row);
        final itemsRaw = data['order_items'];
        final items = (itemsRaw is List)
            ? itemsRaw
                  .map<OrderItem>(
                    (item) =>
                        OrderItem.fromJson(Map<String, dynamic>.from(item)),
                  )
                  .toList()
            : <OrderItem>[];

        final total = items.fold<double>(
          0,
          (sum, item) => sum + (item.unitPrice * item.quantity),
        );

        final tableRaw = data['tables'];
        final tableNumber = tableRaw is Map<String, dynamic>
            ? tableRaw['table_number']?.toString() ?? '-'
            : '-';

        final createdAtRaw = data['created_at']?.toString();

        return CashierOrder(
          orderId: data['id'].toString(),
          tableNumber: tableNumber,
          tableId: data['table_id'].toString(),
          status: data['status']?.toString() ?? 'pending',
          items: items,
          totalAmount: total,
          createdAt: createdAtRaw != null
              ? DateTime.tryParse(createdAtRaw) ?? DateTime.now()
              : DateTime.now(),
        );
      }).toList();

      final selected = state.selectedOrder;
      CashierOrder? updatedSelected;
      if (selected != null) {
        for (final order in orders) {
          if (order.orderId == selected.orderId) {
            updatedSelected = order;
            break;
          }
        }
      }

      state = state.copyWith(
        orders: orders,
        selectedOrder: updatedSelected,
        clearSelectedOrder: selected != null && updatedSelected == null,
        clearError: true,
      );

      await subscribeRealtime(restaurantId);
    } catch (error) {
      state = state.copyWith(error: 'Failed to load payable orders: $error');
    }
  }

  void selectOrder(CashierOrder order) {
    state = state.copyWith(
      selectedOrder: order,
      clearPaymentSuccess: true,
      clearError: true,
    );
  }

  Future<void> processPayment(
    String restaurantId,
    String orderId,
    double amount,
    String method,
  ) async {
    state = state.copyWith(
      isProcessing: true,
      paymentSuccess: false,
      clearError: true,
    );

    try {
      await paymentService.processPayment(
        orderId: orderId,
        restaurantId: restaurantId,
        amount: amount,
        method: method,
      );

      await loadOrders(restaurantId);

      state = state.copyWith(
        isProcessing: false,
        paymentSuccess: true,
        clearSelectedOrder: true,
      );
    } catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: 'Failed to process payment: $error',
      );
    }
  }

  Future<void> cancelOrder(String orderId, String restaurantId) async {
    state = state.copyWith(isProcessing: true, clearError: true);
    try {
      await orderService.cancelOrder(
        orderId: orderId,
        restaurantId: restaurantId,
      );
      state = state.copyWith(
        isProcessing: false,
        clearSelectedOrder: true,
        clearError: true,
      );
      await loadOrders(restaurantId);
    } on PostgrestException catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: error.message == 'ORDER_NOT_CANCELLABLE'
            ? '완료되거나 이미 취소된 주문은 취소할 수 없습니다.'
            : '주문 취소 실패: ${error.message}',
      );
    } catch (error) {
      state = state.copyWith(isProcessing: false, error: '주문 취소 실패: $error');
    }
  }

  void resetPaymentSuccess() {
    if (!state.paymentSuccess) {
      return;
    }
    state = state.copyWith(clearPaymentSuccess: true);
  }

  Future<void> subscribeRealtime(String restaurantId) async {
    if (_restaurantId == restaurantId &&
        _ordersChannel != null &&
        _paymentsChannel != null) {
      return;
    }

    if (_ordersChannel != null) {
      await _ordersChannel!.unsubscribe();
    }
    if (_paymentsChannel != null) {
      await _paymentsChannel!.unsubscribe();
    }

    _restaurantId = restaurantId;

    _ordersChannel = supabase
        .channel('public:cashier_orders:$restaurantId')
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

    _paymentsChannel = supabase
        .channel('public:cashier_payments:$restaurantId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'payments',
          callback: (_) => loadOrders(restaurantId),
        )
        .subscribe();
  }

  @override
  void dispose() {
    _ordersChannel?.unsubscribe();
    _paymentsChannel?.unsubscribe();
    _ordersChannel = null;
    _paymentsChannel = null;
    super.dispose();
  }
}

final paymentProvider = StateNotifierProvider<PaymentNotifier, PaymentState>(
  (ref) => PaymentNotifier(),
);
