import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/payments/payment_total_calculator.dart';
import '../../core/services/order_service.dart';
import '../../core/services/payment_service.dart';
import '../../core/utils/live_sync_scope.dart';
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
    this.completedAt,
  });

  final String orderId;
  final String tableNumber;
  final String tableId;
  final String status;
  final List<OrderItem> items;
  final double totalAmount;
  final DateTime createdAt;
  final DateTime? completedAt;
}

class PaymentState {
  const PaymentState({
    this.orders = const [],
    this.completedOrders = const [],
    this.selectedOrder,
    this.isProcessing = false,
    this.paymentSuccess = false,
    this.error,
  });

  final List<CashierOrder> orders;
  final List<CashierOrder> completedOrders;
  final CashierOrder? selectedOrder;
  final bool isProcessing;
  final bool paymentSuccess;
  final String? error;

  PaymentState copyWith({
    List<CashierOrder>? orders,
    List<CashierOrder>? completedOrders,
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
      completedOrders: completedOrders ?? this.completedOrders,
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

  static const _autoRefreshInterval = Duration(seconds: 2);
  static const _fallbackPollInterval = Duration(seconds: 15);

  RealtimeChannel? _ordersChannel;
  RealtimeChannel? _paymentsChannel;
  String? _restaurantId;
  // Realtime can be delayed or dropped on mobile web. Keep cashier payment
  // readiness moving so kitchen-ready tables do not wait for a manual refresh.
  Timer? _pollTimer;
  String? _pollStoreId;
  bool _realtimeConnected = false;

  Future<void> loadOrders(String storeId) async {
    _restaurantId = storeId;

    try {
      final storePricing = await _loadStorePricing(storeId);
      final response = await supabase
          .from('orders')
          .select(
            'id, table_id, status, created_at, tables(table_number), order_items(id, created_at, menu_item_id, label, display_name, unit_price, quantity, status, item_type, paying_amount_inc_tax, menu_items(name, vat_category))',
          )
          .eq('restaurant_id', storeId)
          // Payability is an order-status fact derived server-side by
          // recalc_order_status (ORDER_LIFECYCLE_STATE_CONTRACT_2026_07_03):
          // serving ⇔ every active item is ready|served.
          .eq('status', 'serving')
          .order('created_at', ascending: true)
          .order('created_at', referencedTable: 'order_items', ascending: true)
          .order('id', referencedTable: 'order_items', ascending: true);

      final orders = response
          .map<CashierOrder?>((row) {
            final data = Map<String, dynamic>.from(row);
            final itemsRaw = data['order_items'];
            final itemRows = itemsRaw is List
                ? itemsRaw
                      .map((item) => Map<String, dynamic>.from(item as Map))
                      .toList()
                : <Map<String, dynamic>>[];
            itemRows.sort(_compareOrderItemRowsByCreatedAt);

            final items = itemRows.map<OrderItem>(OrderItem.fromJson).toList();

            final total = calculatePaymentQuote(
              lines: itemRows.map(_paymentQuoteLineFromRow),
              vatPricingMode: storePricing.vatPricingMode,
              serviceChargeEnabled: storePricing.serviceChargeEnabled,
              serviceChargeRate: storePricing.serviceChargeRate,
            ).payableTotal;

            final tableRaw = data['tables'];
            final tableNumber = tableRaw is Map<String, dynamic>
                ? tableRaw['table_number']?.toString() ?? '-'
                : '-';

            final createdAtRaw = data['created_at']?.toString();

            return CashierOrder(
              orderId: data['id'].toString(),
              tableNumber: tableNumber,
              tableId: data['table_id'].toString(),
              status: 'serving',
              items: items,
              totalAmount: total,
              createdAt: createdAtRaw != null
                  ? DateTime.tryParse(createdAtRaw) ?? DateTime.now()
                  : DateTime.now(),
            );
          })
          .whereType<CashierOrder>()
          .where((order) => order.totalAmount > 0)
          .toList();
      final completedOrders = await _fetchCompletedOrders(
        storeId,
        storePricing,
      );

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
        completedOrders: completedOrders,
        selectedOrder: updatedSelected,
        clearSelectedOrder: selected != null && updatedSelected == null,
        clearError: true,
      );

      await subscribeRealtime(storeId);
    } catch (error) {
      state = state.copyWith(error: 'Failed to load payable orders: $error');
    }
  }

  Future<List<CashierOrder>> _fetchCompletedOrders(
    String storeId,
    _CashierStorePricing storePricing,
  ) async {
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day).toIso8601String();
    final response = await supabase
        .from('orders')
        .select(
          'id, table_id, status, created_at, updated_at, tables(table_number), order_items(id, created_at, menu_item_id, label, display_name, unit_price, quantity, status, item_type, paying_amount_inc_tax, menu_items(name, vat_category))',
        )
        .eq('restaurant_id', storeId)
        .eq('status', 'completed')
        .gte('updated_at', todayStart)
        .order('updated_at', ascending: false)
        .order('created_at', referencedTable: 'order_items', ascending: true)
        .order('id', referencedTable: 'order_items', ascending: true)
        .limit(12);

    return response
        .map<CashierOrder>((row) {
          final data = Map<String, dynamic>.from(row);
          final itemsRaw = data['order_items'];
          final itemRows = itemsRaw is List
              ? itemsRaw
                    .map((item) => Map<String, dynamic>.from(item as Map))
                    .where(
                      (item) =>
                          item['status']?.toString().toLowerCase() !=
                          'cancelled',
                    )
                    .toList()
              : <Map<String, dynamic>>[];
          itemRows.sort(_compareOrderItemRowsByCreatedAt);

          final items = itemRows.map<OrderItem>(OrderItem.fromJson).toList();
          final total = calculatePaymentQuote(
            lines: itemRows.map(_paymentQuoteLineFromRow),
            vatPricingMode: storePricing.vatPricingMode,
            serviceChargeEnabled: storePricing.serviceChargeEnabled,
            serviceChargeRate: storePricing.serviceChargeRate,
          ).payableTotal;

          final tableRaw = data['tables'];
          final tableNumber = tableRaw is Map<String, dynamic>
              ? tableRaw['table_number']?.toString() ?? '-'
              : '-';
          final createdAtRaw = data['created_at']?.toString();
          final updatedAtRaw = data['updated_at']?.toString();

          return CashierOrder(
            orderId: data['id'].toString(),
            tableNumber: tableNumber,
            tableId: data['table_id'].toString(),
            status: data['status']?.toString() ?? 'completed',
            items: items,
            totalAmount: total,
            createdAt: createdAtRaw != null
                ? DateTime.tryParse(createdAtRaw) ?? DateTime.now()
                : DateTime.now(),
            completedAt: updatedAtRaw != null
                ? DateTime.tryParse(updatedAtRaw)
                : null,
          );
        })
        .where((order) => order.totalAmount > 0)
        .toList();
  }

  void selectOrder(CashierOrder order) {
    state = state.copyWith(
      selectedOrder: order,
      clearPaymentSuccess: true,
      clearError: true,
    );
  }

  Future<_CashierStorePricing> _loadStorePricing(String storeId) async {
    final response = await supabase
        .from('restaurants')
        .select(
          'vat_pricing_mode, brands(service_charge_enabled, service_charge_rate)',
        )
        .eq('id', storeId)
        .maybeSingle();
    return _CashierStorePricing.fromJson(response);
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
      _ensureAutoRefresh(storeId);
      return;
    }

    if (_ordersChannel != null) {
      await _ordersChannel!.unsubscribe();
    }
    if (_paymentsChannel != null) {
      await _paymentsChannel!.unsubscribe();
    }
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollStoreId = null;
    _realtimeConnected = false;

    _restaurantId = storeId;

    _ordersChannel = supabase
        .channel(LiveSyncScope.storeChannel('cashier_orders', storeId))
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'orders',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshPaymentOrdersFromRealtime(storeId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'orders',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshPaymentOrdersFromRealtime(storeId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'order_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshPaymentOrdersFromRealtime(storeId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'order_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshPaymentOrdersFromRealtime(storeId),
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.delete,
          schema: 'public',
          table: 'order_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshPaymentOrdersFromRealtime(storeId),
        )
        .subscribe((status, [error]) {
          final connected = status == RealtimeSubscribeStatus.subscribed;
          if (connected != _realtimeConnected) {
            _realtimeConnected = connected;
            _ensureAutoRefresh(storeId);
          }
        });

    _paymentsChannel = supabase
        .channel(LiveSyncScope.storeChannel('cashier_payments', storeId))
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'payments',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshPaymentOrdersFromRealtime(storeId),
        )
        .subscribe((status, [error]) {
          final connected = status == RealtimeSubscribeStatus.subscribed;
          if (connected != _realtimeConnected) {
            _realtimeConnected = connected;
            _ensureAutoRefresh(storeId);
          }
        });
    _ensureAutoRefresh(storeId);
    Future.delayed(_autoRefreshInterval, () {
      if (mounted && !_realtimeConnected && _restaurantId == storeId) {
        _ensureAutoRefresh(storeId);
      }
    });
  }

  void _refreshPaymentOrdersFromRealtime(String storeId) {
    if (!mounted) {
      return;
    }
    unawaited(loadOrders(storeId));
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
        unawaited(loadOrders(storeId));
      }
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _pollTimer = null;
    _pollStoreId = null;
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
      'PAYMENT_AMOUNT_EXCEEDS_REMAINING' =>
        'The payment amount is higher than the remaining order total.',
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

PaymentQuoteLine _paymentQuoteLineFromRow(Map<String, dynamic> row) {
  final menuItemRaw = row['menu_items'];
  String? vatCategory;
  if (menuItemRaw is Map) {
    vatCategory = menuItemRaw['vat_category']?.toString();
  }

  return PaymentQuoteLine(
    unitPrice: _toDoubleValue(row['unit_price']),
    quantity: _toIntValue(row['quantity']),
    status: row['status']?.toString() ?? 'pending',
    itemType: row['item_type']?.toString() ?? 'menu_item',
    vatCategory: row['vat_category']?.toString() ?? vatCategory,
    payingAmountIncTax: _nullableDoubleValue(row['paying_amount_inc_tax']),
  );
}

class _CashierStorePricing {
  const _CashierStorePricing({
    required this.vatPricingMode,
    required this.serviceChargeEnabled,
    required this.serviceChargeRate,
  });

  factory _CashierStorePricing.fromJson(Map<String, dynamic>? json) {
    final brandRaw = json?['brands'];
    final brand = brandRaw is Map
        ? Map<String, dynamic>.from(brandRaw)
        : brandRaw is List && brandRaw.isNotEmpty && brandRaw.first is Map
        ? Map<String, dynamic>.from(brandRaw.first as Map)
        : const <String, dynamic>{};

    return _CashierStorePricing(
      vatPricingMode:
          json?['vat_pricing_mode']?.toString() ?? vatPricingModeExclusive,
      serviceChargeEnabled: brand['service_charge_enabled'] == true,
      serviceChargeRate: _toDoubleValue(brand['service_charge_rate']),
    );
  }

  final String vatPricingMode;
  final bool serviceChargeEnabled;
  final double serviceChargeRate;
}

double _toDoubleValue(dynamic value) {
  return switch (value) {
    num v => v.toDouble(),
    String v => double.tryParse(v) ?? 0,
    _ => 0,
  };
}

double? _nullableDoubleValue(dynamic value) {
  return switch (value) {
    num v => v.toDouble(),
    String v => double.tryParse(v),
    _ => null,
  };
}

int _toIntValue(dynamic value) {
  return switch (value) {
    int v => v,
    num v => v.toInt(),
    String v => int.tryParse(v) ?? 0,
    _ => 0,
  };
}
