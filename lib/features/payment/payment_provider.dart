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

  Future<void> loadOrders(String storeId) async {
    _restaurantId = storeId;

    try {
      final response = await supabase
          .from('orders')
          .select(
            'id, table_id, status, created_at, tables(table_number), order_items(id, menu_item_id, label, unit_price, quantity, status, item_type, menu_items(name))',
          )
          .eq('restaurant_id', storeId)
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

        final total = items
            .where((item) => item.status != 'cancelled')
            .fold<double>(
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

      await subscribeRealtime(storeId);
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

  Future<Map<String, dynamic>?> processPayment(
    String storeId,
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
      final payment = await paymentService.processPayment(
        orderId: orderId,
        storeId: storeId,
        amount: amount,
        method: method,
      );

      await loadOrders(storeId);

      state = state.copyWith(
        isProcessing: false,
        paymentSuccess: true,
        clearSelectedOrder: true,
      );
      return payment;
    } catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: _mapPaymentError(error, 'Failed to process payment'),
      );
      return null;
    }
  }

  Future<void> cancelOrder(String orderId, String storeId) async {
    state = state.copyWith(isProcessing: true, clearError: true);
    try {
      await orderService.cancelOrder(orderId: orderId, storeId: storeId);
      state = state.copyWith(
        isProcessing: false,
        clearSelectedOrder: true,
        clearError: true,
      );
      await loadOrders(storeId);
    } on PostgrestException catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: _mapPaymentError(error, 'Failed to cancel order'),
      );
    } catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: _mapPaymentError(error, 'Failed to cancel order'),
      );
    }
  }

  void resetPaymentSuccess() {
    if (!state.paymentSuccess) {
      return;
    }
    state = state.copyWith(clearPaymentSuccess: true);
  }

  Future<void> subscribeRealtime(String storeId) async {
    if (_restaurantId == storeId &&
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

    _restaurantId = storeId;

    _ordersChannel = supabase
        .channel('public:cashier_orders:$storeId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'orders',
          callback: (_) => loadOrders(storeId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'orders',
          callback: (_) => loadOrders(storeId),
        )
        .subscribe();

    _paymentsChannel = supabase
        .channel('public:cashier_payments:$storeId')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'payments',
          callback: (_) => loadOrders(storeId),
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

class CashierTodaySummary {
  const CashierTodaySummary({
    required this.paymentsCount,
    required this.paymentsTotal,
    required this.paymentsCash,
    required this.paymentsCard,
    required this.paymentsPay,
    required this.serviceCount,
    required this.serviceTotal,
    required this.ordersCompleted,
    required this.ordersCancelled,
    required this.ordersActive,
  });

  final int paymentsCount;
  final double paymentsTotal;
  final double paymentsCash;
  final double paymentsCard;
  final double paymentsPay;
  final int serviceCount;
  final double serviceTotal;
  final int ordersCompleted;
  final int ordersCancelled;
  final int ordersActive;

  factory CashierTodaySummary.fromJson(Map<String, dynamic> json) {
    return CashierTodaySummary(
      paymentsCount: _toInt(json['payments_count']),
      paymentsTotal: _toDouble(json['payments_total']),
      paymentsCash: _toDouble(json['payments_cash']),
      paymentsCard: _toDouble(json['payments_card']),
      paymentsPay: _toDouble(json['payments_pay']),
      serviceCount: _toInt(json['service_count']),
      serviceTotal: _toDouble(json['service_total']),
      ordersCompleted: _toInt(json['orders_completed']),
      ordersCancelled: _toInt(json['orders_cancelled']),
      ordersActive: _toInt(json['orders_active']),
    );
  }

  static int _toInt(dynamic v) => switch (v) {
    int val => val,
    num val => val.toInt(),
    String val => int.tryParse(val) ?? 0,
    _ => 0,
  };

  static double _toDouble(dynamic v) => switch (v) {
    num val => val.toDouble(),
    String val => double.tryParse(val) ?? 0,
    _ => 0,
  };
}

final cashierTodaySummaryProvider = FutureProvider.autoDispose
    .family<CashierTodaySummary, String>((ref, storeId) async {
      final json = await paymentService.fetchCashierTodaySummary(
        storeId: storeId,
      );
      return CashierTodaySummary.fromJson(json);
    });

String _mapPaymentError(Object error, String fallbackPrefix) {
  if (error is PostgrestException) {
    return switch (error.message) {
      'PAYMENT_FORBIDDEN' =>
        'You do not have permission to complete payment for this order.',
      'INVALID_PAYMENT_METHOD' =>
        'The selected payment method is not supported.',
      'PAYMENT_ALREADY_EXISTS' => 'This order has already been paid.',
      'ORDER_NOT_FOUND' => 'The selected order could not be found.',
      'ORDER_NOT_PAYABLE' => 'Only open dine-in orders can be paid.',
      'ORDER_TOTAL_INVALID' =>
        'This order total is invalid and cannot be processed.',
      'PAYMENT_AMOUNT_MISMATCH' =>
        'The payment amount no longer matches the current order total.',
      'ORDER_NOT_CANCELLABLE' =>
        'Only pending or confirmed orders can be cancelled.',
      'ORDER_MUTATION_FORBIDDEN' =>
        'You do not have permission to cancel this order.',
      _ => '$fallbackPrefix: ${error.message}',
    };
  }
  return '$fallbackPrefix: $error';
}
