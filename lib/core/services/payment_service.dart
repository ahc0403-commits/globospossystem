import '../../main.dart';

class PaymentService {
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
