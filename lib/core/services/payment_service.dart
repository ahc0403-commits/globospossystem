import 'package:supabase_flutter/supabase_flutter.dart';

import 'pos_backend.dart';
import '../payments/payment_method_contract.dart';
import '../payments/payment_command_rpc.dart';

class PaymentSplitInput {
  const PaymentSplitInput({required this.method, required this.amount});

  final String method;
  final double amount;
}

class CombinedOrderPaymentInput {
  const CombinedOrderPaymentInput({
    required this.orderId,
    required this.amount,
  });

  final String orderId;
  final double amount;

  Map<String, dynamic> toJson() => {'order_id': orderId, 'amount': amount};
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
  PaymentService({SupabaseClient? client}) : _client = client;

  final SupabaseClient? _client;
  SupabaseClient get _db => _client ?? supabase;

  Future<Map<String, dynamic>> processSinglePaymentCommand({
    required String operationId,
    required String orderId,
    required String storeId,
    required double amount,
    required String method,
    required int expectedPaymentCount,
    required bool requireFullPayment,
    required bool Function() isCurrent,
  }) async {
    final response = await PaymentCommandRpc(_db)
        .call(PaymentCommandRpcKind.execute, {
          'p_operation_id': operationId,
          'p_order_id': orderId,
          'p_store_id': storeId,
          'p_amount': amount,
          'p_method': normalizePaymentMethodInput(method),
          'p_expected_payment_count': expectedPaymentCount,
          'p_require_full_payment': requireFullPayment,
        }, isCurrent: isCurrent);
    return _commandPaymentResult(response, orderId, storeId);
  }

  Future<Map<String, dynamic>> cancelSinglePaymentCommand({
    required String operationId,
    required String orderId,
    required String storeId,
    required bool Function() isCurrent,
  }) async {
    final response = await PaymentCommandRpc(_db).call(
      PaymentCommandRpcKind.cancel,
      {
        'p_operation_id': operationId,
        'p_order_id': orderId,
        'p_store_id': storeId,
      },
      isCurrent: isCurrent,
    );
    if (response is! Map ||
        response['operation_id'] != operationId ||
        response['order_id'] != orderId ||
        response['store_id'] != storeId ||
        !const {'cancelled', 'confirmed'}.contains(response['status'])) {
      throw const FormatException('PAYMENT_CANCELLATION_RESPONSE_INVALID');
    }
    if (response['status'] == 'confirmed') {
      _commandPaymentResult(response['result'], orderId, storeId);
    } else if (response['cancelled_at'] is! String ||
        DateTime.tryParse(response['cancelled_at']) == null) {
      throw const FormatException('PAYMENT_CANCELLATION_RESPONSE_INVALID');
    }
    return Map<String, dynamic>.from(response);
  }

  Map<String, dynamic> _commandPaymentResult(
    dynamic response,
    String orderId,
    String storeId,
  ) {
    if (response is! Map ||
        response['id'] is! String ||
        (response['id'] as String).isEmpty ||
        response['order_id'] != orderId ||
        response['restaurant_id'] != storeId) {
      throw const FormatException('PAYMENT_OPERATION_RESULT_INVALID');
    }
    return Map<String, dynamic>.from(response);
  }

  /// The caller must durably retain this original ID before sending and use
  /// result reconciliation on uncertain delivery. This additive API does not
  /// silently turn legacy callers/retries into a new payment intent.
  Future<Map<String, dynamic>> processPaymentOnce({
    required String operationId,
    required String orderId,
    required String storeId,
    required double amount,
    required String method,
  }) async {
    final result = await _db.rpc(
      'process_payment_once_v1',
      params: {
        'p_operation_id': operationId,
        'p_order_id': orderId,
        'p_store_id': storeId,
        'p_amount': amount,
        'p_method': normalizePaymentMethodInput(method),
      },
    );
    if (result is! Map ||
        result['id'] is! String ||
        result['order_id'] != orderId ||
        result['restaurant_id'] != storeId) {
      throw const FormatException('PAYMENT_OPERATION_RESULT_INVALID');
    }
    return Map<String, dynamic>.from(result);
  }

  /// One bounded set-based lookup; never replay a payment to discover a result.
  Future<List<Map<String, dynamic>>> getPaymentCommandReceipts({
    required String storeId,
    required List<String> operationIds,
    bool Function()? isCurrent,
  }) async {
    if (operationIds.length > 100 || operationIds.any((id) => id.isEmpty)) {
      throw ArgumentError('PAYMENT_RECEIPT_BATCH_INVALID');
    }
    if (operationIds.isEmpty) return const [];
    final ids = operationIds.toSet();
    final response = await PaymentCommandRpc(_db).call(
      PaymentCommandRpcKind.receipts,
      {'p_store_id': storeId, 'p_operation_ids': ids.toList()},
      isCurrent: isCurrent ?? () => true,
    );
    if (response is! List || response.length > ids.length) {
      throw const FormatException('PAYMENT_RECEIPT_RESPONSE_INVALID');
    }
    final seen = <String>{};
    final result = <Map<String, dynamic>>[];
    for (final row in response) {
      if (row is! Map ||
          row['operation_id'] is! String ||
          !ids.contains(row['operation_id']) ||
          !seen.add(row['operation_id']) ||
          row['store_id'] != storeId ||
          row['result'] is! Map ||
          row['payment_id'] != row['result']['id'] ||
          row['order_id'] != row['result']['order_id'] ||
          row['result']['restaurant_id'] != storeId) {
        throw const FormatException('PAYMENT_RECEIPT_RESPONSE_INVALID');
      }
      result.add(Map<String, dynamic>.from(row));
    }
    return result;
  }

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
    final result = await _db.rpc(
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

  Future<Map<String, dynamic>> processCombinedTablePayment({
    required String storeId,
    required List<CombinedOrderPaymentInput> orders,
    required String method,
  }) async {
    if (orders.length < 2) {
      throw ArgumentError(
        'At least two table orders are required for combined payment.',
      );
    }
    final normalizedMethod = normalizePaymentMethodInput(method);
    final result = await _db.rpc(
      'process_combined_table_payment',
      params: {
        'p_store_id': storeId,
        'p_order_amounts': orders.map((order) => order.toJson()).toList(),
        'p_method': normalizedMethod,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> setOrderWetTissueQuantity({
    required String orderId,
    required String storeId,
    required int quantity,
  }) async {
    final result = await _db.rpc(
      'set_order_wet_tissue_quantity',
      params: {
        'p_order_id': orderId,
        'p_store_id': storeId,
        'p_quantity': quantity,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> processNonRevenuePayment({
    required String orderId,
    required String storeId,
    required double amount,
    required String type,
    required String reason,
    String? staffName,
    required String managerPin,
  }) async {
    final result = await _db.rpc(
      'process_non_revenue_payment',
      params: {
        'p_order_id': orderId,
        'p_store_id': storeId,
        'p_amount': amount,
        'p_type': type,
        'p_reason': reason,
        'p_staff_name': staffName,
        'p_manager_pin': managerPin,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> enqueueReceiptPrintJob({
    required String orderId,
    double? receivedAmount,
    bool reprint = false,
  }) async {
    final result = await _db.rpc(
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

  Future<Map<String, dynamic>> enqueueCombinedReceiptPrintJob({
    required String combinedPaymentGroupId,
    double? receivedAmount,
    bool reprint = false,
  }) async {
    final result = await _db.rpc(
      'enqueue_combined_receipt_print_job',
      params: {
        'p_group_id': combinedPaymentGroupId,
        'p_received_amount': receivedAmount,
        'p_reprint': reprint,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> printFirstReceiptCopy({
    required String orderId,
    double? receivedAmount,
  }) => enqueueReceiptPrintJob(
    orderId: orderId,
    receivedAmount: receivedAmount,
    reprint: false,
  );

  Future<Map<String, dynamic>> reprintReceipt({
    required String orderId,
    double? receivedAmount,
  }) => enqueueReceiptPrintJob(
    orderId: orderId,
    receivedAmount: receivedAmount,
    reprint: true,
  );

  Future<Map<String, dynamic>> markOrderItemService({
    required String itemId,
    required String storeId,
    required String reason,
    required String managerPin,
  }) async {
    final result = await _db.rpc(
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
    final result = await _db.rpc(
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
            'id, restaurant_id, table_id, status, created_at, updated_at, tables(table_number), order_items(id, menu_option_snapshot, created_at, status, label, notes, unit_price, quantity, is_service_item, service_reason, vat_amount, paying_amount_inc_tax, menu_items(name, name_ko, name_vi, name_en))',
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

    final result = await _db.rpc('record_payment_adjustment', params: params);
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
    final result = await _db.rpc(
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
