import '../../main.dart';

class StoreService {
  Future<Map<String, dynamic>> createRestaurant({
    required String name,
    required String slug,
    required String operationMode,
    String? address,
    double? perPersonCharge,
    String? brandId,
    String storeType = 'direct',
  }) async {
    final result = await supabase.rpc(
      'admin_create_restaurant',
      params: {
        'p_name': name,
        'p_slug': slug,
        'p_operation_mode': operationMode.toLowerCase(),
        'p_address': address,
        'p_per_person_charge': perPersonCharge,
        'p_brand_id': brandId,
        'p_store_type': storeType,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<void> updateRestaurant({
    required String id,
    required String name,
    required String slug,
    required String operationMode,
    String? address,
    double? perPersonCharge,
    String? brandId,
    String storeType = 'direct',
  }) async {
    await supabase.rpc(
      'admin_update_restaurant',
      params: {
        'p_restaurant_id': id,
        'p_name': name,
        'p_slug': slug,
        'p_operation_mode': operationMode.toLowerCase(),
        'p_address': address,
        'p_per_person_charge': perPersonCharge,
        'p_brand_id': brandId,
        'p_store_type': storeType,
      },
    );
  }

  Future<void> updateRestaurantSettings({
    required String id,
    required String name,
    required String operationMode,
    String? address,
    double? perPersonCharge,
  }) async {
    await supabase.rpc(
      'admin_update_restaurant_settings',
      params: {
        'p_restaurant_id': id,
        'p_name': name,
        'p_operation_mode': operationMode.toLowerCase(),
        'p_address': address,
        'p_per_person_charge': perPersonCharge,
      },
    );
  }

  Future<void> deactivateRestaurant(String id) async {
    await supabase.rpc(
      'admin_deactivate_restaurant',
      params: {'p_restaurant_id': id},
    );
  }
}

final restaurantService = StoreService();
