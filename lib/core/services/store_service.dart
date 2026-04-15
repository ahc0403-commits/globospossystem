import '../../main.dart';

class StoreService {
  Future<Map<String, dynamic>> createStore({
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

  Future<Map<String, dynamic>> createRestaurant({
    required String name,
    required String slug,
    required String operationMode,
    String? address,
    double? perPersonCharge,
    String? brandId,
    String storeType = 'direct',
  }) {
    return createStore(
      name: name,
      slug: slug,
      operationMode: operationMode,
      address: address,
      perPersonCharge: perPersonCharge,
      brandId: brandId,
      storeType: storeType,
    );
  }

  Future<void> updateStore({
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
        'p_store_id': id,
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

  Future<void> updateRestaurant({
    required String id,
    required String name,
    required String slug,
    required String operationMode,
    String? address,
    double? perPersonCharge,
    String? brandId,
    String storeType = 'direct',
  }) {
    return updateStore(
      id: id,
      name: name,
      slug: slug,
      operationMode: operationMode,
      address: address,
      perPersonCharge: perPersonCharge,
      brandId: brandId,
      storeType: storeType,
    );
  }

  Future<void> updateStoreSettings({
    required String id,
    required String name,
    required String operationMode,
    String? address,
    double? perPersonCharge,
  }) async {
    await supabase.rpc(
      'admin_update_restaurant_settings',
      params: {
        'p_store_id': id,
        'p_name': name,
        'p_operation_mode': operationMode.toLowerCase(),
        'p_address': address,
        'p_per_person_charge': perPersonCharge,
      },
    );
  }

  Future<void> updateRestaurantSettings({
    required String id,
    required String name,
    required String operationMode,
    String? address,
    double? perPersonCharge,
  }) {
    return updateStoreSettings(
      id: id,
      name: name,
      operationMode: operationMode,
      address: address,
      perPersonCharge: perPersonCharge,
    );
  }

  Future<void> deactivateStore(String id) async {
    await supabase.rpc(
      'admin_deactivate_restaurant',
      params: {'p_store_id': id},
    );
  }

  Future<void> deactivateRestaurant(String id) {
    return deactivateStore(id);
  }
}

final storeService = StoreService();
final restaurantService = storeService;
