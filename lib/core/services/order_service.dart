import '../../main.dart';

class OrderService {
  Future<Map<String, dynamic>> createOrder({
    required String storeId,
    required String tableId,
    required List<Map<String, dynamic>> items,
  }) async {
    final result = await supabase.rpc(
      'create_order',
      params: {'p_store_id': storeId, 'p_table_id': tableId, 'p_items': items},
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

  Future<List<Map<String, dynamic>>> addItemsToOrder({
    required String orderId,
    required String storeId,
    required List<Map<String, dynamic>> items,
  }) async {
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
