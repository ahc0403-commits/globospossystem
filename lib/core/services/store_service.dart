import 'dart:async';

import '../../main.dart';

class StoreService {
  Future<Map<String, dynamic>> createStore({
    required String name,
    required String slug,
    required String operationMode,
    String? address,
    double? perPersonCharge,
    String? brandId,
    String? taxEntityId,
    String storeType = 'direct',
  }) async {
    final usesLegalEntity = taxEntityId != null && taxEntityId.isNotEmpty;
    final result = await supabase
        .rpc(
          usesLegalEntity
              ? 'admin_create_restaurant_v2'
              : 'admin_create_restaurant',
          params: usesLegalEntity
              ? {
                  'p_name': name,
                  'p_slug': slug,
                  'p_operation_mode': operationMode.toLowerCase(),
                  'p_address': address,
                  'p_per_person_charge': perPersonCharge,
                  'p_tax_entity_id': taxEntityId,
                  'p_brand_id': brandId,
                }
              : {
                  'p_name': name,
                  'p_slug': slug,
                  'p_operation_mode': operationMode.toLowerCase(),
                  'p_address': address,
                  'p_per_person_charge': perPersonCharge,
                  'p_brand_id': brandId,
                  'p_store_type': storeType,
                },
        )
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException(
            'Store creation timed out before the server returned a result.',
          ),
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
    String? taxEntityId,
    String storeType = 'direct',
  }) {
    return createStore(
      name: name,
      slug: slug,
      operationMode: operationMode,
      address: address,
      perPersonCharge: perPersonCharge,
      brandId: brandId,
      taxEntityId: taxEntityId,
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
    String? taxEntityId,
    String storeType = 'direct',
  }) async {
    final usesLegalEntity = taxEntityId != null && taxEntityId.isNotEmpty;
    await supabase
        .rpc(
          usesLegalEntity
              ? 'admin_update_restaurant_v2'
              : 'admin_update_restaurant',
          params: usesLegalEntity
              ? {
                  'p_store_id': id,
                  'p_name': name,
                  'p_slug': slug,
                  'p_operation_mode': operationMode.toLowerCase(),
                  'p_address': address,
                  'p_per_person_charge': perPersonCharge,
                  'p_tax_entity_id': taxEntityId,
                  'p_brand_id': brandId,
                }
              : {
                  'p_store_id': id,
                  'p_name': name,
                  'p_slug': slug,
                  'p_operation_mode': operationMode.toLowerCase(),
                  'p_address': address,
                  'p_per_person_charge': perPersonCharge,
                  'p_brand_id': brandId,
                  'p_store_type': storeType,
                },
        )
        .timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException(
            'Store update timed out before the server returned a result.',
          ),
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
    String? taxEntityId,
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
      taxEntityId: taxEntityId,
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

  Future<Map<String, dynamic>> purgeInactiveStore({
    required String id,
    required String confirmationSlug,
  }) async {
    final result = await supabase.rpc(
      'admin_purge_inactive_store',
      params: {'p_store_id': id, 'p_confirmation_slug': confirmationSlug},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  /// Closes a store while preserving its point-in-time sales history.
  Future<Map<String, dynamic>> closeStore(String id, String reason) async {
    final result = await supabase.rpc(
      'admin_close_store',
      params: {'p_store_id': id, 'p_reason': reason},
    );
    return Map<String, dynamic>.from(result as Map);
  }
}

final storeService = StoreService();
final restaurantService = storeService;
