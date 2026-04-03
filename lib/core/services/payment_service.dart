import '../../main.dart';

class PaymentService {
  Future<Map<String, dynamic>> processPayment({
    required String orderId,
    required String restaurantId,
    required double amount,
    required String method,
  }) async {
    final result = await supabase.rpc(
      'process_payment',
      params: {
        'p_order_id': orderId,
        'p_restaurant_id': restaurantId,
        'p_amount': amount,
        'p_method': method,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }
}

final paymentService = PaymentService();
