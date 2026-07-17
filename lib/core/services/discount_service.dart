import '../../main.dart';

class DiscountService {
  Future<Map<String, dynamic>> applyOrderDiscount({
    required String orderId,
    required String storeId,
    required String type,
    required String mode,
    required double value,
    required String proofStoragePath,
    required String managerPin,
    String? reason,
    String? couponCode,
  }) async {
    final result = await supabase.rpc(
      'apply_order_discount',
      params: {
        'p_order_id': orderId,
        'p_store_id': storeId,
        'p_type': type,
        'p_mode': mode,
        'p_value': value,
        'p_reason': reason,
        'p_coupon_code': couponCode,
        'p_proof_storage_path': proofStoragePath,
        'p_manager_pin': managerPin,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> voidOrderDiscount({
    required String discountId,
    required String storeId,
    required String reason,
  }) async {
    final result = await supabase.rpc(
      'void_order_discount',
      params: {
        'p_discount_id': discountId,
        'p_store_id': storeId,
        'p_reason': reason,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }
}

final discountService = DiscountService();
