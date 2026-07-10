import '../../main.dart';

class OrderService {
  bool _isRpcSignatureMismatch(Object error, String functionName) {
    final message = error.toString().toLowerCase();
    if (!message.contains(functionName.toLowerCase())) {
      return false;
    }

    return message.contains('could not find the function') ||
        message.contains('function public.') ||
        message.contains('does not exist') ||
        message.contains('no function matches');
  }

  Future<Map<String, dynamic>> createOrder({
    required String storeId,
    required String tableId,
    required List<Map<String, dynamic>> items,
    String? clientMutationId,
  }) async {
    if (clientMutationId != null) {
      try {
        final result = await supabase.rpc(
          'create_order_with_client_mutation_id',
          params: {
            'p_store_id': storeId,
            'p_table_id': tableId,
            'p_items': items,
            'p_client_mutation_id': clientMutationId,
          },
        );
        return Map<String, dynamic>.from(result as Map);
      } catch (error) {
        if (!_isRpcSignatureMismatch(
          error,
          'create_order_with_client_mutation_id',
        )) {
          rethrow;
        }
      }
    }

    final result = await supabase.rpc(
      'create_order',
      params: {'p_store_id': storeId, 'p_table_id': tableId, 'p_items': items},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> createDeliveryOrder({
    required String storeId,
    required List<Map<String, dynamic>> items,
  }) async {
    final result = await supabase.rpc(
      'create_delivery_order',
      params: {'p_store_id': storeId, 'p_items': items},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> createBuffetOrder({
    required String storeId,
    required String tableId,
    required int guestCount,
    List<Map<String, dynamic>> extraItems = const [],
  }) async {
    final result = await supabase.rpc(
      'create_buffet_order',
      params: {
        'p_store_id': storeId,
        'p_table_id': tableId,
        'p_guest_count': guestCount,
        'p_extra_items': extraItems,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> createStaffMealOrder({
    required String storeId,
    required List<Map<String, dynamic>> items,
    String? staffUserId,
    String? reason,
    required String managerPin,
  }) async {
    final result = await supabase.rpc(
      'create_staff_meal_order',
      params: {
        'p_store_id': storeId,
        'p_items': items,
        'p_staff_user_id': staffUserId,
        'p_reason': reason,
        'p_manager_pin': managerPin,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> updateOrderGuestCount({
    required String orderId,
    required String storeId,
    required int guestCount,
  }) async {
    final result = await supabase.rpc(
      'update_order_guest_count',
      params: {
        'p_order_id': orderId,
        'p_store_id': storeId,
        'p_guest_count': guestCount,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<List<Map<String, dynamic>>> addItemsToOrder({
    required String orderId,
    required String storeId,
    required List<Map<String, dynamic>> items,
    String? clientMutationId,
  }) async {
    if (clientMutationId != null) {
      try {
        final result = await supabase.rpc(
          'add_items_to_order_with_client_mutation_id',
          params: {
            'p_order_id': orderId,
            'p_store_id': storeId,
            'p_items': items,
            'p_client_mutation_id': clientMutationId,
          },
        );
        return (result as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
      } catch (error) {
        if (!_isRpcSignatureMismatch(
          error,
          'add_items_to_order_with_client_mutation_id',
        )) {
          rethrow;
        }
      }
    }

    final result = await supabase.rpc(
      'add_items_to_order',
      params: {'p_order_id': orderId, 'p_store_id': storeId, 'p_items': items},
    );
    return (result as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<void> updateOrderItemStatus({
    required String itemId,
    required String storeId,
    required String status,
  }) async {
    await supabase.rpc(
      'update_order_item_status',
      params: {
        'p_item_id': itemId,
        'p_store_id': storeId,
        'p_new_status': status,
      },
    );
  }

  Future<Map<String, dynamic>> cancelOrder({
    required String orderId,
    required String storeId,
  }) async {
    final result = await supabase.rpc(
      'cancel_order',
      params: {'p_order_id': orderId, 'p_store_id': storeId},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<void> cancelOrderItem({
    required String itemId,
    required String storeId,
  }) async {
    await supabase.rpc(
      'cancel_order_item',
      params: {'p_item_id': itemId, 'p_store_id': storeId},
    );
  }

  Future<void> editOrderItemQuantity({
    required String itemId,
    required String storeId,
    required int newQuantity,
  }) async {
    await supabase.rpc(
      'edit_order_item_quantity',
      params: {
        'p_item_id': itemId,
        'p_store_id': storeId,
        'p_new_quantity': newQuantity,
      },
    );
  }

  Future<Map<String, dynamic>> transferOrderTable({
    required String orderId,
    required String storeId,
    required String newTableId,
  }) async {
    final result = await supabase.rpc(
      'transfer_order_table',
      params: {
        'p_order_id': orderId,
        'p_store_id': storeId,
        'p_new_table_id': newTableId,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }
}

final orderService = OrderService();
