import '../../main.dart';

class OrderService {
  Future<Map<String, dynamic>> createOrder({
    required String restaurantId,
    required String tableId,
    required List<Map<String, dynamic>> items,
  }) async {
    final result = await supabase.rpc(
      'create_order',
      params: {
        'p_restaurant_id': restaurantId,
        'p_table_id': tableId,
        'p_items': items,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<Map<String, dynamic>> createBuffetOrder({
    required String restaurantId,
    required String tableId,
    required int guestCount,
    List<Map<String, dynamic>> extraItems = const [],
  }) async {
    final result = await supabase.rpc(
      'create_buffet_order',
      params: {
        'p_restaurant_id': restaurantId,
        'p_table_id': tableId,
        'p_guest_count': guestCount,
        'p_extra_items': extraItems,
      },
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<List<Map<String, dynamic>>> addItemsToOrder({
    required String orderId,
    required String restaurantId,
    required List<Map<String, dynamic>> items,
  }) async {
    final result = await supabase.rpc(
      'add_items_to_order',
      params: {
        'p_order_id': orderId,
        'p_restaurant_id': restaurantId,
        'p_items': items,
      },
    );
    return (result as List)
        .map((e) => Map<String, dynamic>.from(e as Map))
        .toList();
  }

  Future<Map<String, dynamic>> cancelOrder({
    required String orderId,
    required String restaurantId,
  }) async {
    final result = await supabase.rpc(
      'cancel_order',
      params: {'p_order_id': orderId, 'p_restaurant_id': restaurantId},
    );
    return Map<String, dynamic>.from(result as Map);
  }
}

final orderService = OrderService();
