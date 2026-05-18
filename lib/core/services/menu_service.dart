import '../../main.dart';

class MenuService {
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

  Future<List<Map<String, dynamic>>> fetchCategories(String storeId) async {
    final response = await supabase
        .from('menu_categories')
        .select()
        .eq('restaurant_id', storeId)
        .order('sort_order');
    return response
        .map<Map<String, dynamic>>((c) => Map<String, dynamic>.from(c))
        .toList();
  }

  Future<List<Map<String, dynamic>>> fetchItems(String storeId) async {
    final response = await supabase
        .from('menu_items')
        .select()
        .eq('restaurant_id', storeId)
        .order('sort_order');
    return response
        .map<Map<String, dynamic>>((i) => Map<String, dynamic>.from(i))
        .toList();
  }

  Future<void> addCategory({
    required String storeId,
    required String name,
    required int sortOrder,
  }) async {
    try {
      await supabase.rpc(
        'admin_create_menu_category',
        params: {
          'p_store_id': storeId,
          'p_name': name,
          'p_sort_order': sortOrder,
        },
      );
    } catch (error) {
      if (!_isRpcSignatureMismatch(error, 'admin_create_menu_category')) {
        rethrow;
      }

      await supabase.rpc(
        'admin_create_menu_category',
        params: {
          'p_restaurant_id': storeId,
          'p_name': name,
          'p_sort_order': sortOrder,
        },
      );
    }
  }

  Future<void> addMenuItem({
    required String storeId,
    required String categoryId,
    required String name,
    required double price,
    required int sortOrder,
  }) async {
    final itemParams = {
      'p_category_id': categoryId,
      'p_name': name,
      'p_price': price,
      'p_sort_order': sortOrder,
      'p_is_available': true,
    };

    try {
      await supabase.rpc(
        'admin_create_menu_item',
        params: {'p_store_id': storeId, ...itemParams},
      );
    } catch (error) {
      if (!_isRpcSignatureMismatch(error, 'admin_create_menu_item')) {
        rethrow;
      }

      await supabase.rpc(
        'admin_create_menu_item',
        params: {'p_restaurant_id': storeId, ...itemParams},
      );
    }
  }

  Future<void> toggleAvailability(String itemId, bool isAvailable) async {
    await supabase.rpc(
      'admin_update_menu_item',
      params: {'p_item_id': itemId, 'p_is_available': isAvailable},
    );
  }

  Future<void> updateMenuItem({
    required String itemId,
    required String name,
    required double price,
  }) async {
    await supabase.rpc(
      'admin_update_menu_item',
      params: {'p_item_id': itemId, 'p_name': name, 'p_price': price},
    );
  }
}

final menuService = MenuService();
