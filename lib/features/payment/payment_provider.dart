import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/models/fulfillment_mode.dart';
import '../../core/payments/payment_total_calculator.dart';
import '../../core/services/order_service.dart';
import '../../core/services/payment_service.dart';
import '../../core/utils/live_sync_scope.dart';
import '../../l10n/app_localizations.dart';
import '../../main.dart';
import '../order/order_model.dart';

class CashierOrder {
  const CashierOrder({
    required this.orderId,
    required this.tableNumber,
    required this.tableId,
    required this.status,
    required this.orderPurpose,
    required this.orderSource,
    required this.items,
    required this.menuSubtotal,
    required this.serviceChargeTotal,
    required this.serviceItemTotal,
    required this.fixedChargeTotal,
    required this.discountTotal,
    required this.vatTotal,
    required this.totalAmount,
    required this.paidTotal,
    required this.paymentCount,
    required this.remainingDue,
    required this.createdAt,
    this.completedAt,
    this.activeDiscount,
    this.fulfillmentMode = FulfillmentMode.posPrint,
    this.emergencyModeActive = false,
    this.unservedQuantity = 0,
    this.floorServedQuantityByItemId = const {},
  });

  final String orderId;
  final String tableNumber;
  final String tableId;
  final String status;
  final String orderPurpose;
  final String orderSource;
  final List<OrderItem> items;
  final double menuSubtotal;
  final double serviceChargeTotal;
  final double serviceItemTotal;
  final double fixedChargeTotal;
  final double discountTotal;
  final double vatTotal;
  final double totalAmount;
  final double paidTotal;
  final int paymentCount;
  final double remainingDue;
  final DateTime createdAt;
  final DateTime? completedAt;
  final ActiveOrderDiscount? activeDiscount;
  final FulfillmentMode fulfillmentMode;
  final bool emergencyModeActive;
  final int unservedQuantity;
  final Map<String, int> floorServedQuantityByItemId;

  bool get isStaffMeal => orderPurpose == 'staff_meal';
  bool get isQrOrder => orderSource == 'qr';
  int get serviceItemCount => items
      .where(
        (item) =>
            item.isServiceItem && item.status.toLowerCase() != 'cancelled',
      )
      .length;
  int get wetTissueQuantity => items
      .where(
        (item) =>
            item.itemType == 'wet_tissue_charge' &&
            item.status.toLowerCase() != 'cancelled',
      )
      .fold(0, (total, item) => total + item.quantity);
}

class ActiveOrderDiscount {
  const ActiveOrderDiscount({
    required this.id,
    required this.type,
    required this.mode,
    required this.value,
    required this.amount,
    required this.status,
  });

  final String id;
  final String type;
  final String mode;
  final double value;
  final double amount;
  final String status;

  factory ActiveOrderDiscount.fromJson(Map<String, dynamic> json) {
    return ActiveOrderDiscount(
      id: json['id'].toString(),
      type: json['discount_type']?.toString() ?? 'manual',
      mode: json['discount_mode']?.toString() ?? 'amount',
      value: _toDoubleValue(json['discount_value']),
      amount: _toDoubleValue(json['discount_amount']),
      status: json['status']?.toString() ?? 'active',
    );
  }
}

class CashierOrderSearchResult {
  const CashierOrderSearchResult({
    required this.orderId,
    required this.tableNumber,
    required this.status,
    required this.orderSource,
    required this.createdAt,
  });

  final String orderId;
  final String tableNumber;
  final String status;
  final String orderSource;
  final DateTime createdAt;

  String get orderCode {
    final normalized = orderId.trim();
    return normalized.length >= 8 ? normalized.substring(0, 8) : normalized;
  }

  bool get isQrOrder => orderSource == 'qr';
  bool get isPayable => status == 'serving';

  factory CashierOrderSearchResult.fromJson(Map<String, dynamic> json) {
    final tableRaw = json['tables'];
    final tableNumber = tableRaw is Map<String, dynamic>
        ? tableRaw['table_number']?.toString() ?? '-'
        : json['order_purpose']?.toString() == 'staff_meal'
        ? 'STAFF'
        : '-';
    final createdAtRaw = json['created_at']?.toString();
    return CashierOrderSearchResult(
      orderId: json['id']?.toString() ?? '',
      tableNumber: tableNumber,
      status: json['status']?.toString() ?? 'pending',
      orderSource: json['order_source']?.toString() ?? 'staff',
      createdAt: createdAtRaw == null
          ? DateTime.now()
          : DateTime.tryParse(createdAtRaw) ?? DateTime.now(),
    );
  }
}

class QrOrderLedgerBatch {
  const QrOrderLedgerBatch({
    required this.batchNo,
    required this.createdAt,
    required this.items,
  });

  final int batchNo;
  final DateTime createdAt;
  final List<QrOrderLedgerItem> items;

  QrOrderLedgerBatch copyWith({List<QrOrderLedgerItem>? items}) {
    return QrOrderLedgerBatch(
      batchNo: batchNo,
      createdAt: createdAt,
      items: items ?? this.items,
    );
  }

  factory QrOrderLedgerBatch.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items_snapshot'];
    return QrOrderLedgerBatch(
      batchNo: switch (json['batch_no']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 1,
        _ => 1,
      },
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0),
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) => QrOrderLedgerItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }
}

class QrOrderLedgerItem {
  const QrOrderLedgerItem({
    this.menuItemId = '',
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.nameKo,
    this.nameVi,
    this.nameEn,
  });

  final String menuItemId;
  final String name;
  final int quantity;
  final double unitPrice;
  final String? nameKo;
  final String? nameVi;
  final String? nameEn;

  double get lineTotal => unitPrice * quantity;

  QrOrderLedgerItem copyWith({String? nameKo, String? nameVi, String? nameEn}) {
    return QrOrderLedgerItem(
      menuItemId: menuItemId,
      name: name,
      quantity: quantity,
      unitPrice: unitPrice,
      nameKo: nameKo ?? this.nameKo,
      nameVi: nameVi ?? this.nameVi,
      nameEn: nameEn ?? this.nameEn,
    );
  }

  String localizedName(String languageCode) {
    final localized = switch (languageCode) {
      'vi' => nameVi,
      'en' => nameEn,
      _ => nameKo,
    };
    final value = localized?.trim() ?? '';
    if (value.isNotEmpty) return value;
    return switch (languageCode) {
      'vi' => 'Món',
      'en' => 'Item',
      _ => '메뉴',
    };
  }

  factory QrOrderLedgerItem.fromJson(Map<String, dynamic> json) {
    return QrOrderLedgerItem(
      menuItemId: json['menu_item_id']?.toString() ?? '',
      name: json['name']?.toString() ?? '-',
      quantity: switch (json['quantity']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 0,
        _ => 0,
      },
      unitPrice: _toDoubleValue(json['unit_price']),
    );
  }
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
  RealtimeChannel? _emergencyChannel;
  String? _restaurantId;
  // Realtime can be delayed or dropped on mobile web. Keep cashier payment
  // readiness moving so kitchen-ready tables do not wait for a manual refresh.
  Timer? _pollTimer;
  String? _pollStoreId;
  bool _realtimeConnected = false;

  Future<void> loadOrders(String storeId) async {
    _restaurantId = storeId;

    try {
      await supabase.rpc(
        'refresh_store_order_promotions',
        params: {'p_store_id': storeId},
      );
      final storePricing = await _loadStorePricing(storeId);
      final response = await supabase
          .from('orders')
          .select(
            'id, table_id, status, order_purpose, order_source, fulfillment_mode_snapshot, created_at, tables(table_number), payments(amount_portion), order_discounts(id, discount_type, discount_mode, discount_value, discount_amount, status), order_items(id, created_at, menu_item_id, label, display_name, unit_price, quantity, status, item_type, is_service_item, service_reason, vat_rate, paying_amount_inc_tax, combo_components, menu_items(name, name_vi, name_en, vat_category))',
          )
          .eq('restaurant_id', storeId)
          // Payability is an order-status fact derived server-side by
          // recalc_order_status (ORDER_LIFECYCLE_STATE_CONTRACT_2026_07_03):
          // serving ⇔ every active item is ready|served.
          .eq('status', 'serving')
          .order('created_at', ascending: true)
          .order('created_at', referencedTable: 'order_items', ascending: true)
          .order('id', referencedTable: 'order_items', ascending: true);

      final emergencySummaries = await _loadEmergencySummaries(
        response.map((row) => row['id'].toString()).toList(growable: false),
      );
      final emergencyItemProgress = await _loadEmergencyItemProgress(
        response.map((row) => row['id'].toString()).toList(growable: false),
      );

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

            final activeDiscount = _activeDiscountFromRaw(
              data['order_discounts'],
            );
            final quote = calculatePaymentQuote(
              lines: itemRows.map(_paymentQuoteLineFromRow),
              vatPricingMode: storePricing.vatPricingMode,
              serviceChargeEnabled: storePricing.serviceChargeEnabled,
              serviceChargeRate: storePricing.serviceChargeRate,
              discountTotal: activeDiscount?.amount ?? 0,
            );
            final paidTotal = _paidTotalFromRaw(data['payments']);
            final paymentCount = _paymentCountFromRaw(data['payments']);
            final remainingDue = _remainingDue(quote.payableTotal, paidTotal);

            final tableRaw = data['tables'];
            final tableNumber = tableRaw is Map<String, dynamic>
                ? tableRaw['table_number']?.toString() ?? '-'
                : data['order_purpose']?.toString() == 'staff_meal'
                ? 'STAFF'
                : '-';

            final createdAtRaw = data['created_at']?.toString();
            final emergencySummary = emergencySummaries[data['id'].toString()];

            return CashierOrder(
              orderId: data['id'].toString(),
              tableNumber: tableNumber,
              tableId: data['table_id']?.toString() ?? '',
              status: 'serving',
              orderPurpose: data['order_purpose']?.toString() ?? 'customer',
              orderSource: data['order_source']?.toString() ?? 'staff',
              items: items,
              menuSubtotal: quote.menuSubtotal,
              serviceChargeTotal: quote.serviceChargeTotal,
              serviceItemTotal: quote.serviceItemTotal,
              fixedChargeTotal: quote.fixedChargeTotal,
              discountTotal: quote.discountTotal,
              vatTotal: quote.vatTotal,
              totalAmount: quote.payableTotal,
              paidTotal: paidTotal,
              paymentCount: paymentCount,
              remainingDue: remainingDue,
              createdAt: createdAtRaw != null
                  ? DateTime.tryParse(createdAtRaw) ?? DateTime.now()
                  : DateTime.now(),
              activeDiscount: activeDiscount,
              fulfillmentMode: FulfillmentMode.fromValue(
                data['fulfillment_mode_snapshot'],
              ),
              emergencyModeActive: emergencySummary != null,
              unservedQuantity: emergencySummary ?? 0,
              floorServedQuantityByItemId:
                  emergencyItemProgress[data['id'].toString()] ?? const {},
            );
          })
          .whereType<CashierOrder>()
          .where(_shouldShowCashierOrder)
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

  Future<Map<String, int>> _loadEmergencySummaries(
    List<String> orderIds,
  ) async {
    if (orderIds.isEmpty) return const {};
    try {
      final raw = await supabase.rpc(
        'get_emergency_order_summaries',
        params: {'p_order_ids': orderIds},
      );
      if (raw is! List) return const {};
      return {
        for (final row in raw.whereType<Map>())
          if ((row['order_id']?.toString() ?? '').isNotEmpty)
            row['order_id'].toString(): switch (row['unserved_quantity']) {
              int value => value,
              num value => value.toInt(),
              String value => int.tryParse(value) ?? 0,
              _ => 0,
            },
      };
    } catch (_) {
      // The payment surface must remain usable while a migration is pending or
      // the emergency summary service is temporarily unavailable.
      return const {};
    }
  }

  Future<Map<String, Map<String, int>>> _loadEmergencyItemProgress(
    List<String> orderIds,
  ) async {
    if (orderIds.isEmpty) return const {};
    try {
      final raw = await supabase
          .from('emergency_fulfillment_items')
          .select(
            'order_id, order_item_id, floor_served_quantity, '
            'emergency_fulfillment_sessions!inner(status)',
          )
          .inFilter('order_id', orderIds)
          .eq('is_cancelled', false)
          .eq('emergency_fulfillment_sessions.status', 'active');
      final result = <String, Map<String, int>>{};
      for (final row in raw) {
        final orderId = row['order_id']?.toString() ?? '';
        final orderItemId = row['order_item_id']?.toString() ?? '';
        if (orderId.isEmpty || orderItemId.isEmpty) continue;
        result.putIfAbsent(
          orderId,
          () => <String, int>{},
        )[orderItemId] = switch (row['floor_served_quantity']) {
          int value => value,
          num value => value.toInt(),
          String value => int.tryParse(value) ?? 0,
          _ => 0,
        };
      }
      return result;
    } catch (_) {
      // Keep cashier payment available while item-level progress is unavailable.
      return const {};
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
          'id, table_id, status, order_purpose, order_source, fulfillment_mode_snapshot, created_at, updated_at, tables(table_number), payments(amount_portion), order_discounts(id, discount_type, discount_mode, discount_value, discount_amount, status), order_items(id, created_at, menu_item_id, label, display_name, unit_price, quantity, status, item_type, is_service_item, service_reason, vat_rate, paying_amount_inc_tax, combo_components, menu_items(name, name_vi, name_en, vat_category))',
        )
        .eq('restaurant_id', storeId)
        .eq('status', 'completed')
        .gte('updated_at', todayStart)
        .order('updated_at', ascending: false)
        .order('created_at', referencedTable: 'order_items', ascending: true)
        .order('id', referencedTable: 'order_items', ascending: true)
        .limit(12);

    return response.map<CashierOrder>((row) {
      final data = Map<String, dynamic>.from(row);
      final itemsRaw = data['order_items'];
      final itemRows = itemsRaw is List
          ? itemsRaw
                .map((item) => Map<String, dynamic>.from(item as Map))
                .where(
                  (item) =>
                      item['status']?.toString().toLowerCase() != 'cancelled',
                )
                .toList()
          : <Map<String, dynamic>>[];
      itemRows.sort(_compareOrderItemRowsByCreatedAt);

      final items = itemRows.map<OrderItem>(OrderItem.fromJson).toList();
      final consumedDiscount = _consumedDiscountFromRaw(
        data['order_discounts'],
      );
      final quote = calculatePaymentQuote(
        lines: itemRows.map(_paymentQuoteLineFromRow),
        vatPricingMode: storePricing.vatPricingMode,
        serviceChargeEnabled: storePricing.serviceChargeEnabled,
        serviceChargeRate: storePricing.serviceChargeRate,
        discountTotal: consumedDiscount?.amount ?? 0,
      );
      final paidTotal = _paidTotalFromRaw(data['payments']);
      final paymentCount = _paymentCountFromRaw(data['payments']);

      final tableRaw = data['tables'];
      final tableNumber = tableRaw is Map<String, dynamic>
          ? tableRaw['table_number']?.toString() ?? '-'
          : data['order_purpose']?.toString() == 'staff_meal'
          ? 'STAFF'
          : '-';
      final createdAtRaw = data['created_at']?.toString();
      final updatedAtRaw = data['updated_at']?.toString();

      return CashierOrder(
        orderId: data['id'].toString(),
        tableNumber: tableNumber,
        tableId: data['table_id']?.toString() ?? '',
        status: data['status']?.toString() ?? 'completed',
        items: items,
        orderPurpose: data['order_purpose']?.toString() ?? 'customer',
        orderSource: data['order_source']?.toString() ?? 'staff',
        menuSubtotal: quote.menuSubtotal,
        serviceChargeTotal: quote.serviceChargeTotal,
        serviceItemTotal: quote.serviceItemTotal,
        fixedChargeTotal: quote.fixedChargeTotal,
        discountTotal: quote.discountTotal,
        vatTotal: quote.vatTotal,
        totalAmount: quote.payableTotal,
        paidTotal: paidTotal,
        paymentCount: paymentCount,
        remainingDue: _remainingDue(quote.payableTotal, paidTotal),
        createdAt: createdAtRaw != null
            ? DateTime.tryParse(createdAtRaw) ?? DateTime.now()
            : DateTime.now(),
        completedAt: updatedAtRaw != null
            ? DateTime.tryParse(updatedAtRaw)
            : null,
        activeDiscount: consumedDiscount,
        fulfillmentMode: FulfillmentMode.fromValue(
          data['fulfillment_mode_snapshot'],
        ),
      );
    }).toList();
  }

  void selectOrder(CashierOrder order) {
    state = state.copyWith(
      selectedOrder: order,
      clearPaymentSuccess: true,
      clearError: true,
    );
  }

  void clearSelection() {
    state = state.copyWith(
      clearSelectedOrder: true,
      clearPaymentSuccess: true,
      clearError: true,
    );
  }

  Future<CashierOrderSearchResult?> searchActiveOrderForCashier({
    required String storeId,
    required String query,
  }) async {
    final normalizedQuery = _normalizeCashierSearch(query);
    if (normalizedQuery.isEmpty) {
      return null;
    }

    try {
      final rpcResult = await supabase.rpc(
        'search_active_order_for_cashier',
        params: {'p_store_id': storeId, 'p_query': query},
      );
      return _cashierOrderSearchResultFromRpc(rpcResult);
    } catch (error) {
      if (!_isCashierSearchRpcMissing(error)) {
        rethrow;
      }
    }

    final rows = await supabase
        .from('orders')
        .select(
          'id, table_id, status, order_purpose, order_source, created_at, tables(table_number)',
        )
        .eq('restaurant_id', storeId)
        .inFilter('status', ['pending', 'confirmed', 'serving'])
        .order('created_at', ascending: false)
        .limit(100);

    CashierOrderSearchResult? partialMatch;
    for (final raw in rows) {
      final result = CashierOrderSearchResult.fromJson(
        Map<String, dynamic>.from(raw),
      );
      final orderCode = _shortCashierSearchCode(result.orderId);
      final normalizedCode = _normalizeCashierSearch(orderCode);
      final normalizedId = _normalizeCashierSearch(result.orderId);
      final normalizedTable = _normalizeCashierSearch(result.tableNumber);

      if (normalizedCode == normalizedQuery ||
          normalizedId.startsWith(normalizedQuery) ||
          normalizedTable == normalizedQuery) {
        return result;
      }

      if (partialMatch == null &&
          (normalizedCode.contains(normalizedQuery) ||
              normalizedTable.contains(normalizedQuery))) {
        partialMatch = result;
      }
    }

    return partialMatch;
  }

  Future<List<QrOrderLedgerBatch>> fetchQrOrderLedger(String orderId) async {
    final response = await supabase
        .from('qr_order_batches')
        .select('batch_no, items_snapshot, created_at')
        .eq('order_id', orderId)
        .order('batch_no', ascending: true);

    final batches = response
        .map(
          (row) => QrOrderLedgerBatch.fromJson(Map<String, dynamic>.from(row)),
        )
        .toList(growable: false);
    final menuItemIds = batches
        .expand((batch) => batch.items)
        .map((item) => item.menuItemId)
        .where((id) => id.isNotEmpty)
        .toSet()
        .toList(growable: false);
    if (menuItemIds.isEmpty) return batches;

    final menuRows = await supabase
        .from('menu_items')
        .select('id, name, name_vi, name_en')
        .inFilter('id', menuItemIds);
    final namesById = <String, Map<String, dynamic>>{
      for (final row in menuRows)
        row['id'].toString(): Map<String, dynamic>.from(row),
    };

    return batches
        .map(
          (batch) => batch.copyWith(
            items: batch.items
                .map((item) {
                  final names = namesById[item.menuItemId];
                  if (names == null) return item;
                  return item.copyWith(
                    nameKo: names['name']?.toString(),
                    nameVi: names['name_vi']?.toString(),
                    nameEn: names['name_en']?.toString(),
                  );
                })
                .toList(growable: false),
          ),
        )
        .toList(growable: false);
  }

  Future<bool> showOnCustomerDisplay({
    required String storeId,
    required CashierOrder order,
  }) async {
    final l10n = lookupAppLocalizations(const Locale('vi'));
    final items = order.items
        .where((item) => item.status.toLowerCase() != 'cancelled')
        .map(
          (item) => <String, dynamic>{
            'name': item.itemType == 'wet_tissue_charge'
                ? l10n.cashierWetTissueCharge
                : item.localizedName('vi'),
            'quantity': item.quantity,
            'amount': item.isServiceItem
                ? 0
                : item.payingAmountIncTax != null &&
                      item.payingAmountIncTax! > 0
                ? item.payingAmountIncTax
                : item.unitPrice * item.quantity,
          },
        )
        .toList(growable: false);

    try {
      await supabase.rpc(
        'show_customer_payment_display',
        params: {
          'p_store_id': storeId,
          'p_order_id': order.orderId,
          'p_payload': {
            'phase': 'payment',
            'display_revision': DateTime.now().microsecondsSinceEpoch
                .toString(),
            'order_id': order.orderId,
            'locale_code': 'vi',
            'table_number': order.tableNumber,
            'items': items,
            'subtotal': order.menuSubtotal,
            'service_charge': order.serviceChargeTotal,
            'discount': order.discountTotal,
            'vat': order.vatTotal,
            'total': order.remainingDue,
          },
        },
      );
      return true;
    } catch (error) {
      state = state.copyWith(error: 'Failed to show customer display: $error');
      return false;
    }
  }

  Future<bool> showReceiptOnCustomerDisplay({
    required String storeId,
    required String orderId,
    required String receiptId,
  }) async {
    try {
      await supabase.rpc(
        'show_customer_receipt_display',
        params: {
          'p_store_id': storeId,
          'p_order_id': orderId,
          'p_receipt_id': receiptId,
        },
      );
      return true;
    } catch (_) {
      // A customer display is optional. Receipt presentation must never change
      // the already-committed payment result.
      return false;
    }
  }

  CashierOrderSearchResult? _cashierOrderSearchResultFromRpc(Object? raw) {
    if (raw == null) {
      return null;
    }
    if (raw is Map<String, dynamic>) {
      return CashierOrderSearchResult.fromJson(raw);
    }
    if (raw is Map) {
      return CashierOrderSearchResult.fromJson(Map<String, dynamic>.from(raw));
    }
    return null;
  }

  bool _isCashierSearchRpcMissing(Object error) {
    final message = error.toString().toLowerCase();
    final functionName = 'search_active_order_for_cashier';
    if (!message.contains(functionName)) {
      return false;
    }
    if (error is PostgrestException && error.code == 'PGRST202') {
      return true;
    }
    return message.contains('could not find the function') ||
        message.contains('function public.') ||
        message.contains('does not exist') ||
        message.contains('no function matches');
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

  Future<Map<String, dynamic>?> processCombinedTablePayment(
    String storeId,
    List<CashierOrder> orders,
    String method,
  ) async {
    state = state.copyWith(
      isProcessing: true,
      paymentSuccess: false,
      clearError: true,
    );

    try {
      final result = await paymentService.processCombinedTablePayment(
        storeId: storeId,
        orders: orders
            .map(
              (order) => CombinedOrderPaymentInput(
                orderId: order.orderId,
                amount: order.remainingDue,
              ),
            )
            .toList(growable: false),
        method: method,
      );

      await loadOrders(storeId);
      state = state.copyWith(
        isProcessing: false,
        paymentSuccess: true,
        clearSelectedOrder: true,
      );
      return result;
    } catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: _mapPaymentError(
          error,
          'Failed to process combined table payment',
        ),
      );
      return null;
    }
  }

  Future<bool> prepareCombinedTablePayment({
    required String storeId,
    required Map<String, int> wetTissueQuantities,
  }) async {
    state = state.copyWith(isProcessing: true, clearError: true);
    try {
      for (final entry in wetTissueQuantities.entries) {
        await paymentService.setOrderWetTissueQuantity(
          orderId: entry.key,
          storeId: storeId,
          quantity: entry.value,
        );
      }
      await loadOrders(storeId);
      state = state.copyWith(isProcessing: false, clearError: true);
      return true;
    } catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: _mapPaymentError(
          error,
          'Failed to prepare combined table payment',
        ),
      );
      return false;
    }
  }

  Future<bool> setWetTissueQuantity({
    required String storeId,
    required String orderId,
    required int quantity,
  }) async {
    state = state.copyWith(isProcessing: true, clearError: true);
    try {
      await paymentService.setOrderWetTissueQuantity(
        orderId: orderId,
        storeId: storeId,
        quantity: quantity,
      );
      await loadOrders(storeId);
      state = state.copyWith(isProcessing: false, clearError: true);
      return true;
    } catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: _mapPaymentError(error, 'Failed to update wet tissues'),
      );
      return false;
    }
  }

  Future<Map<String, dynamic>?> processNonRevenuePayment({
    required String storeId,
    required String orderId,
    required double amount,
    required String type,
    required String reason,
    String? staffName,
    required String managerPin,
  }) async {
    state = state.copyWith(
      isProcessing: true,
      paymentSuccess: false,
      clearError: true,
    );

    try {
      final payment = await paymentService.processNonRevenuePayment(
        orderId: orderId,
        storeId: storeId,
        amount: amount,
        type: type,
        reason: reason,
        staffName: staffName,
        managerPin: managerPin,
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
        error: _mapPaymentError(error, 'Failed to close non-revenue order'),
      );
      return null;
    }
  }

  Future<List<Map<String, dynamic>>?> processPaymentSplits(
    String storeId,
    String orderId,
    double orderTotal,
    List<PaymentSplitInput> splits,
  ) async {
    state = state.copyWith(
      isProcessing: true,
      paymentSuccess: false,
      clearError: true,
    );

    try {
      final payments = await paymentService.processPaymentSplits(
        orderId: orderId,
        storeId: storeId,
        orderTotal: orderTotal,
        splits: splits,
      );

      await loadOrders(storeId);

      state = state.copyWith(
        isProcessing: false,
        paymentSuccess: true,
        clearSelectedOrder: true,
      );
      return payments;
    } catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: _mapPaymentError(error, 'Failed to process split payment'),
      );
      return null;
    }
  }

  Future<bool> markOrderItemService({
    required String storeId,
    required String itemId,
    required String reason,
    required String managerPin,
  }) async {
    state = state.copyWith(isProcessing: true, clearError: true);
    try {
      await paymentService.markOrderItemService(
        itemId: itemId,
        storeId: storeId,
        reason: reason,
        managerPin: managerPin,
      );
      await loadOrders(storeId);
      state = state.copyWith(isProcessing: false, clearError: true);
      return true;
    } catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: _mapPaymentError(error, 'Failed to mark service item'),
      );
      return false;
    }
  }

  Future<bool> unmarkOrderItemService({
    required String storeId,
    required String itemId,
    required String reason,
    required String managerPin,
  }) async {
    state = state.copyWith(isProcessing: true, clearError: true);
    try {
      await paymentService.unmarkOrderItemService(
        itemId: itemId,
        storeId: storeId,
        reason: reason,
        managerPin: managerPin,
      );
      await loadOrders(storeId);
      state = state.copyWith(isProcessing: false, clearError: true);
      return true;
    } catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: _mapPaymentError(error, 'Failed to unmark service item'),
      );
      return false;
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

  Future<bool> cancelOrderItem(String itemId, String storeId) async {
    state = state.copyWith(isProcessing: true, clearError: true);
    try {
      await orderService.cancelOrderItem(itemId: itemId, storeId: storeId);
      await loadOrders(storeId);
      state = state.copyWith(isProcessing: false, clearError: true);
      return true;
    } on PostgrestException catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: _mapPaymentError(error, 'Failed to cancel order item'),
      );
      return false;
    } catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: _mapPaymentError(error, 'Failed to cancel order item'),
      );
      return false;
    }
  }

  Future<bool> restoreCancelledOrder(String orderId, String storeId) async {
    state = state.copyWith(isProcessing: true, clearError: true);
    try {
      await orderService.restoreCancelledOrder(
        orderId: orderId,
        storeId: storeId,
      );
      await loadOrders(storeId);
      state = state.copyWith(isProcessing: false, clearError: true);
      return true;
    } catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: _mapPaymentError(error, 'Failed to restore order'),
      );
      return false;
    }
  }

  Future<bool> restoreCancelledOrderItem(String itemId, String storeId) async {
    state = state.copyWith(isProcessing: true, clearError: true);
    try {
      await orderService.restoreCancelledOrderItem(
        itemId: itemId,
        storeId: storeId,
      );
      await loadOrders(storeId);
      state = state.copyWith(isProcessing: false, clearError: true);
      return true;
    } catch (error) {
      state = state.copyWith(
        isProcessing: false,
        error: _mapPaymentError(error, 'Failed to restore order item'),
      );
      return false;
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
        _paymentsChannel != null &&
        _emergencyChannel != null) {
      _ensureAutoRefresh(storeId);
      return;
    }

    if (_ordersChannel != null) {
      await _ordersChannel!.unsubscribe();
    }
    if (_paymentsChannel != null) {
      await _paymentsChannel!.unsubscribe();
    }
    if (_emergencyChannel != null) {
      await _emergencyChannel!.unsubscribe();
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

    _emergencyChannel = supabase
        .channel(LiveSyncScope.storeChannel('cashier_emergency', storeId))
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'emergency_fulfillment_items',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => _refreshPaymentOrdersFromRealtime(storeId),
        )
        .subscribe();
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
    _emergencyChannel?.unsubscribe();
    _ordersChannel = null;
    _paymentsChannel = null;
    _emergencyChannel = null;
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
    required this.staffMealCount,
    required this.staffMealTotal,
    required this.discountTotal,
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
  final int staffMealCount;
  final double staffMealTotal;
  final double discountTotal;
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
      staffMealCount: _toInt(json['staff_meal_count']),
      staffMealTotal: _toDouble(json['staff_meal_total']),
      discountTotal: _toDouble(json['discount_total']),
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
      'RESTAURANT_DAILY_SALES_CLOSED' => 'RESTAURANT_DAILY_SALES_CLOSED',
      'PAYMENT_FORBIDDEN' =>
        'You do not have permission to complete payment for this order.',
      'INVALID_PAYMENT_METHOD' =>
        'The selected payment method is not supported.',
      'PAYMENT_ALREADY_EXISTS' => 'This order has already been paid.',
      'ORDER_NOT_FOUND' => 'The selected order could not be found.',
      'ORDER_NOT_PAYABLE' => 'Only open dine-in orders can be paid.',
      'WET_TISSUE_FORBIDDEN' =>
        'You do not have permission to update the wet-tissue charge.',
      'WET_TISSUE_QUANTITY_INVALID' =>
        'Wet-tissue quantity must be between 0 and 100.',
      'WET_TISSUE_CUSTOMER_ORDER_ONLY' =>
        'Wet-tissue charges apply only to customer orders.',
      'WET_TISSUE_AFTER_PAYMENT' =>
        'Wet-tissue quantity cannot be changed after payment has started.',
      'ORDER_TOTAL_INVALID' =>
        'This order total is invalid and cannot be processed.',
      'PAYMENT_AMOUNT_EXCEEDS_REMAINING' =>
        'The payment amount is higher than the remaining order total.',
      'PAYMENT_AMOUNT_MISMATCH' =>
        'The payment amount no longer matches the current order total.',
      'DISCOUNT_PIN_REJECTED' => 'Manager PIN is incorrect.',
      'DISCOUNT_PIN_NOT_CONFIGURED' =>
        'Set a discount manager PIN before applying discounts.',
      'DISCOUNT_PROOF_REQUIRED' => 'A discount proof photo is required.',
      'DISCOUNT_REASON_REQUIRED' => 'Enter a reason for the discount.',
      'DISCOUNT_ALREADY_ACTIVE' => 'This order already has an active discount.',
      'DISCOUNT_ORDER_NOT_PAYABLE' =>
        'Discounts can be applied only when the order is ready for payment.',
      'STAFF_MEAL_SERVICE_REQUIRED' =>
        'Staff meals must be closed with SERVICE.',
      'STAFF_MEAL_FORBIDDEN' =>
        'You do not have permission to create staff meals.',
      'NON_REVENUE_FORBIDDEN' =>
        'You do not have permission to close non-revenue orders.',
      'NON_REVENUE_TYPE_INVALID' =>
        'Select a valid non-revenue classification.',
      'NON_REVENUE_REASON_REQUIRED' =>
        'Enter a reason for the non-revenue checkout.',
      'NON_REVENUE_STAFF_REQUIRED' =>
        'Enter the staff member name for a staff meal.',
      'NON_REVENUE_ORDER_NOT_PAYABLE' =>
        'Only orders ready for payment can be excluded from revenue.',
      'NON_REVENUE_AFTER_PAYMENT' =>
        'An order cannot be excluded from revenue after payment has started.',
      'SERVICE_MARK_FORBIDDEN' =>
        'You do not have permission to mark service items.',
      'SERVICE_REASON_REQUIRED' => 'Enter a reason for the service item.',
      'SERVICE_MARK_AFTER_PAYMENT' =>
        'Service items cannot be changed after payment has started.',
      'SERVICE_MARK_PURPOSE_UNSUPPORTED' =>
        'Staff meals already close as service payments.',
      'FULL_SERVICE_NOT_ALLOWED' =>
        'Use SERVICE payment when the whole order is service.',
      'SERVICE_MARK_ITEM_TYPE' => 'Only menu items can be marked as service.',
      'SERVICE_MARK_ITEM_CANCELLED' =>
        'Cancelled items cannot be marked as service.',
      'SERVICE_MARK_ITEM_NOT_PROVIDED' =>
        'Only ready or served items can be marked as service.',
      'SERVICE_MARK_ALREADY' => 'This item is already marked as service.',
      'SERVICE_MARK_NOT_SET' => 'This item is not marked as service.',
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
    id: row['id']?.toString() ?? '',
    unitPrice: _toDoubleValue(row['unit_price']),
    quantity: _toIntValue(row['quantity']),
    status: row['status']?.toString() ?? 'pending',
    itemType: row['item_type']?.toString() ?? 'menu_item',
    isServiceItem: switch (row['is_service_item']) {
      bool value => value,
      String value => value.toLowerCase() == 'true',
      _ => false,
    },
    vatCategory: row['vat_category']?.toString() ?? vatCategory,
    vatRate: _nullableDoubleValue(row['vat_rate']),
    payingAmountIncTax: _nullableDoubleValue(row['paying_amount_inc_tax']),
  );
}

ActiveOrderDiscount? _activeDiscountFromRaw(dynamic raw) {
  return _discountFromRaw(raw, 'active');
}

ActiveOrderDiscount? _consumedDiscountFromRaw(dynamic raw) {
  return _discountFromRaw(raw, 'consumed');
}

bool _shouldShowCashierOrder(CashierOrder order) {
  return order.remainingDue > 0 || order.discountTotal > 0 || order.isStaffMeal;
}

String _shortCashierSearchCode(String orderId) {
  final normalized = orderId.trim();
  return normalized.length >= 8 ? normalized.substring(0, 8) : normalized;
}

String _normalizeCashierSearch(String raw) {
  return raw.trim().replaceAll('#', '').toLowerCase();
}

double _paidTotalFromRaw(dynamic raw) {
  if (raw is! List) return 0;
  return raw.fold<double>(0, (sum, item) {
    if (item is! Map) return sum;
    final row = Map<String, dynamic>.from(item);
    return sum + _toDoubleValue(row['amount_portion']);
  });
}

int _paymentCountFromRaw(dynamic raw) {
  if (raw is! List) return 0;
  return raw.whereType<Map>().length;
}

double _remainingDue(double totalAmount, double paidTotal) {
  final remaining = totalAmount - paidTotal;
  return remaining <= 0.01 ? 0 : remaining;
}

ActiveOrderDiscount? _discountFromRaw(dynamic raw, String status) {
  if (raw is! List) return null;
  for (final item in raw) {
    if (item is! Map) continue;
    final row = Map<String, dynamic>.from(item);
    if ((row['status']?.toString() ?? '') == status) {
      return ActiveOrderDiscount.fromJson(row);
    }
  }
  return null;
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
