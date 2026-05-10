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
    if (!isSupportedPaymentMethodInput(split.method)) {
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

  Future<Map<String, dynamic>> processPayment({
    required String orderId,
    required String storeId,
    required double amount,
    required String method,
  }) async {
    final result = await supabase.rpc(
      'process_payment',
      params: {
        'p_order_id': orderId,
        'p_store_id': storeId,
        'p_amount': amount,
        'p_method': method,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>?> fetchPaymentDetail(String paymentId) async {
    final payment = await supabase
        .from('payments')
        .select()
        .eq('id', paymentId)
        .maybeSingle();
    if (payment == null) return null;

    final paymentMap = Map<String, dynamic>.from(payment);
    final orderId = paymentMap['order_id']?.toString();
    Map<String, dynamic>? orderMap;
    Map<String, dynamic>? jobMap;

    if (orderId != null && orderId.isNotEmpty) {
      final order = await supabase
          .from('orders')
          .select(
            'id, restaurant_id, table_id, status, created_at, updated_at, tables(table_number), order_items(status, unit_price, quantity, paying_amount_inc_tax)',
          )
          .eq('id', orderId)
          .maybeSingle();
      if (order != null) {
        orderMap = Map<String, dynamic>.from(order);
        final itemsRaw = orderMap['order_items'];
        final orderTotal = itemsRaw is List
            ? itemsRaw
                  .map((item) => Map<String, dynamic>.from(item))
                  .where((item) => item['status']?.toString() != 'cancelled')
                  .fold<double>(
                    0,
                    (sum, item) =>
                        sum +
                        _toDouble(
                          item['paying_amount_inc_tax'],
                        ).clamp(0, double.infinity),
                  )
            : 0.0;
        orderMap['order_total_amount'] = orderTotal > 0
            ? orderTotal
            : (itemsRaw is List
                  ? itemsRaw
                        .map((item) => Map<String, dynamic>.from(item))
                        .where(
                          (item) => item['status']?.toString() != 'cancelled',
                        )
                        .fold<double>(
                          0,
                          (sum, item) =>
                              sum +
                              (_toDouble(item['unit_price']) *
                                  _toDouble(item['quantity'])),
                        )
                  : 0.0);
      }

      final jobs = await supabase
          .from('einvoice_jobs')
          .select(
            'id, ref_id, sid, status, cqt_report_status, issuance_status, lookup_url, redinvoice_requested, send_order_payload, request_einvoice_payload, created_at, updated_at',
          )
          .eq('order_id', orderId)
          .order('created_at', ascending: false)
          .limit(1);
      if (jobs.isNotEmpty) {
        jobMap = Map<String, dynamic>.from(jobs.first);
      }
    }

    return {'payment': paymentMap, 'order': orderMap, 'einvoice_job': jobMap};
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

final paymentService = PaymentService();
