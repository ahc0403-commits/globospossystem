import '../../main.dart';
import '../payments/payment_method_contract.dart';

class PaymentSplitInput {
  const PaymentSplitInput({required this.method, required this.amount});

  final String method;
  final double amount;
}

String? validatePaymentSplits(List<PaymentSplitInput> splits, double total) {
  if (splits.isEmpty) return 'At least one payment split is required.';
  if (total <= 0) return 'Order total is invalid.';

  var sum = 0.0;
  for (final split in splits) {
    final normalizedMethod = normalizePaymentMethodInput(split.method);
    if (!isSupportedPaymentMethodInput(normalizedMethod)) {
      return 'Unsupported payment method: ${split.method}';
    }
    if (split.amount <= 0) {
      return 'Payment split amounts must be greater than zero.';
    }
    sum += split.amount;
  }

  if ((sum - total).abs() > 0.01) {
    return 'Payment splits must equal the order total.';
  }

  return null;
}

class PaymentService {
  double _toDouble(dynamic value) {
    return switch (value) {
      num v => v.toDouble(),
      String v => double.tryParse(v) ?? 0,
      _ => 0,
    };
  }

  bool _toBool(dynamic value) {
    return switch (value) {
      bool v => v,
      String v => v.toLowerCase() == 'true',
      _ => false,
    };
  }

  Future<Map<String, dynamic>> processPayment({
    required String orderId,
    required String storeId,
    required double amount,
    required String method,
  }) async {
    final normalizedMethod = normalizePaymentMethodInput(method);
    final result = await supabase.rpc(
      'process_payment',
      params: {
        'p_order_id': orderId,
        'p_store_id': storeId,
        'p_amount': amount,
        'p_method': normalizedMethod,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> enqueueReceiptPrintJob({
    required String orderId,
    double? receivedAmount,
    bool reprint = false,
  }) async {
    final result = await supabase.rpc(
      receivedAmount == null
          ? 'enqueue_receipt_print_job'
          : 'enqueue_cash_receipt_print_job',
      params: {
        'p_order_id': orderId,
        if (receivedAmount != null) 'p_received_amount': receivedAmount,
        'p_reprint': reprint,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> markOrderItemService({
    required String itemId,
    required String storeId,
    required String reason,
    required String managerPin,
  }) async {
    final result = await supabase.rpc(
      'mark_order_item_service',
      params: {
        'p_item_id': itemId,
        'p_store_id': storeId,
        'p_reason': reason,
        'p_manager_pin': managerPin,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> unmarkOrderItemService({
    required String itemId,
    required String storeId,
    required String reason,
    required String managerPin,
  }) async {
    final result = await supabase.rpc(
      'unmark_order_item_service',
      params: {
        'p_item_id': itemId,
        'p_store_id': storeId,
        'p_reason': reason,
        'p_manager_pin': managerPin,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>?> fetchPaymentDetail(
    String paymentId, {
    String? storeId,
  }) async {
    final paymentQuery = supabase.from('payments').select().eq('id', paymentId);
    final payment = storeId == null || storeId.isEmpty
        ? await paymentQuery.maybeSingle()
        : await paymentQuery.eq('restaurant_id', storeId).maybeSingle();
    if (payment == null) return null;

    final paymentMap = Map<String, dynamic>.from(payment);
    final orderId = paymentMap['order_id']?.toString();
    Map<String, dynamic>? orderMap;
    Map<String, dynamic>? jobMap;

    if (orderId != null && orderId.isNotEmpty) {
      final scopedStoreId = storeId == null || storeId.isEmpty
          ? paymentMap['restaurant_id']?.toString()
          : storeId;
      final orderQuery = supabase
          .from('orders')
          .select(
            'id, restaurant_id, table_id, status, created_at, updated_at, tables(table_number), order_items(id, created_at, status, label, unit_price, quantity, is_service_item, service_reason, paying_amount_inc_tax, menu_items(name, name_vi))',
          )
          .eq('id', orderId);
      final order = scopedStoreId == null || scopedStoreId.isEmpty
          ? await orderQuery
                .order(
                  'created_at',
                  referencedTable: 'order_items',
                  ascending: true,
                )
                .order('id', referencedTable: 'order_items', ascending: true)
                .maybeSingle()
          : await orderQuery
                .eq('restaurant_id', scopedStoreId)
                .order(
                  'created_at',
                  referencedTable: 'order_items',
                  ascending: true,
                )
                .order('id', referencedTable: 'order_items', ascending: true)
                .maybeSingle();
      if (order != null) {
        orderMap = Map<String, dynamic>.from(order);
        final storeId = orderMap['restaurant_id']?.toString();
        if (storeId != null && storeId.isNotEmpty) {
          try {
            final restaurant = await supabase
                .from('restaurants')
                .select('name')
                .eq('id', storeId)
                .maybeSingle();
            orderMap['restaurant_name'] = restaurant?['name']?.toString();
          } catch (_) {
            orderMap['restaurant_name'] = null;
          }
        }
        final itemsRaw = orderMap['order_items'];
        final itemRows = itemsRaw is List
            ? itemsRaw
                  .map((item) => Map<String, dynamic>.from(item as Map))
                  .toList()
            : <Map<String, dynamic>>[];
        itemRows.sort(_compareOrderItemRowsByCreatedAt);
        orderMap['order_items'] = itemRows;
        final billableItemRows = itemRows
            .where(
              (item) =>
                  item['status']?.toString().toLowerCase() != 'cancelled' &&
                  !_toBool(item['is_service_item']),
            )
            .toList(growable: false);
        final orderTotal = billableItemRows.fold<double>(
          0,
          (sum, item) =>
              sum +
              _toDouble(
                item['paying_amount_inc_tax'],
              ).clamp(0, double.infinity),
        );
        orderMap['order_total_amount'] = orderTotal > 0
            ? orderTotal
            : billableItemRows.fold<double>(
                0,
                (sum, item) =>
                    sum +
                    (_toDouble(item['unit_price']) *
                        _toDouble(item['quantity'])),
              );
      }

      final jobs = await supabase
          .from('meinvoice_jobs')
          .select(
            'id, misa_ref_id, transaction_id, status, tax_authority_code, invoice_number, buyer_kind, buyer_snapshot, line_items_snapshot, created_at, updated_at',
          )
          .eq('order_id', orderId)
          .order('created_at', ascending: false)
          .limit(1);
      if (jobs.isNotEmpty) {
        jobMap = Map<String, dynamic>.from(jobs.first);
        jobMap['ref_id'] = jobMap['misa_ref_id'] ?? jobMap['id'];
        jobMap['sid'] = jobMap['transaction_id'];
        jobMap['cqt_report_status'] = jobMap['tax_authority_code'];
        jobMap['issuance_status'] =
            jobMap['invoice_number'] ?? jobMap['status'];
        jobMap['lookup_url'] = null;
        jobMap['redinvoice_requested'] =
            jobMap['buyer_kind']?.toString() != 'anonymous';
      }
    }

    final adjustments = await supabase
        .from('payment_adjustments')
        .select()
        .eq('payment_id', paymentId)
        .order('created_at', ascending: false);

    return {
      'payment': paymentMap,
      'order': orderMap,
      'einvoice_job': jobMap,
      'adjustments': adjustments
          .map((row) => Map<String, dynamic>.from(row))
          .toList(),
    };
  }

  Future<Map<String, dynamic>> recordPaymentAdjustment({
    required String paymentId,
    required String adjustmentType,
    double? amount,
    required String reason,
  }) async {
    final params = <String, dynamic>{
      'p_payment_id': paymentId,
      'p_adjustment_type': adjustmentType,
      'p_reason': reason,
    };
    if (amount != null) {
      params['p_amount'] = amount;
    }

    final result = await supabase.rpc(
      'record_payment_adjustment',
      params: params,
    );
    if (result is List && result.isNotEmpty && result.first is Map) {
      return Map<String, dynamic>.from(result.first as Map);
    }
    return Map<String, dynamic>.from(result as Map);
  }

  Future<List<Map<String, dynamic>>> processPaymentSplits({
    required String orderId,
    required String storeId,
    required double orderTotal,
    required List<PaymentSplitInput> splits,
  }) async {
    final validationError = validatePaymentSplits(splits, orderTotal);
    if (validationError != null) {
      throw ArgumentError(validationError);
    }

    final payments = <Map<String, dynamic>>[];
    for (final split in splits) {
      final payment = await processPayment(
        orderId: orderId,
        storeId: storeId,
        amount: split.amount,
        method: split.method,
      );
      payments.add(payment);
    }

    return payments;
  }

  Future<Map<String, dynamic>> fetchCashierTodaySummary({
    required String storeId,
  }) async {
    final result = await supabase.rpc(
      'get_cashier_today_summary',
      params: {'p_store_id': storeId},
    );
    return Map<String, dynamic>.from(result as Map);
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

final paymentService = PaymentService();
