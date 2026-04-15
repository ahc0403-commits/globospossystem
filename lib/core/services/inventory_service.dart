import '../../main.dart';

class InventoryService {
  Future<List<Map<String, dynamic>>> fetchIngredients(
    String storeId,
  ) async {
    final r = await supabase.rpc(
      'get_inventory_ingredient_catalog',
      params: {'p_store_id': storeId},
    );
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<void> createIngredient({
    required String storeId,
    required String name,
    required String unit,
    double? currentStock,
    double? reorderPoint,
    double? costPerUnit,
    String? supplierName,
  }) async {
    await supabase.rpc(
      'create_inventory_item',
      params: {
        'p_store_id': storeId,
        'p_name': name,
        'p_unit': unit,
        'p_current_stock': currentStock,
        'p_reorder_point': reorderPoint,
        'p_cost_per_unit': costPerUnit,
        'p_supplier_name': supplierName,
      },
    );
  }

  Future<void> updateIngredient(
    String id,
    Map<String, dynamic> data, {
    required String storeId,
  }) async {
    final patch = <String, dynamic>{};

    if (data.containsKey('name')) {
      patch['name'] = data['name'];
    }
    if (data.containsKey('unit')) {
      patch['unit'] = data['unit'];
    }
    if (data.containsKey('current_stock') && data['current_stock'] != null) {
      patch['current_stock'] = data['current_stock'];
    }
    if (data.containsKey('reorder_point')) {
      patch['reorder_point'] = data['reorder_point'];
    }
    if (data.containsKey('cost_per_unit')) {
      patch['cost_per_unit'] = data['cost_per_unit'];
    }
    if (data.containsKey('supplier_name')) {
      final supplierName = data['supplier_name'];
      patch['supplier_name'] =
          supplierName is String && supplierName.trim().isEmpty
          ? null
          : supplierName;
    }

    await supabase.rpc(
      'update_inventory_item',
      params: {
        'p_item_id': id,
        'p_store_id': storeId,
        'p_patch': patch,
      },
    );
  }

  Future<void> deleteIngredient(
    String id, {
    required String storeId,
  }) async {
    await supabase
        .from('inventory_items')
        .delete()
        .eq('id', id)
        .eq('restaurant_id', storeId);
  }

  Future<void> restockIngredient({
    required String storeId,
    required String ingredientId,
    required double quantityG,
    String? note,
  }) async {
    await supabase.rpc(
      'restock_inventory_item',
      params: {
        'p_store_id': storeId,
        'p_ingredient_id': ingredientId,
        'p_quantity_g': quantityG,
        'p_note': note,
      },
    );
  }

  Future<void> recordWaste({
    required String storeId,
    required String ingredientId,
    required double quantityG,
    String? note,
  }) async {
    await supabase.rpc(
      'record_inventory_waste',
      params: {
        'p_store_id': storeId,
        'p_ingredient_id': ingredientId,
        'p_quantity_g': quantityG,
        'p_note': note,
      },
    );
  }

  Future<List<Map<String, dynamic>>> fetchMenuItems(String storeId) async {
    final r = await supabase
        .from('menu_items')
        .select('id, name, sort_order')
        .eq('restaurant_id', storeId)
        .order('sort_order');
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<List<Map<String, dynamic>>> fetchAllRecipes(
    String storeId,
  ) async {
    final r = await supabase.rpc(
      'get_inventory_recipe_catalog',
      params: {'p_store_id': storeId, 'p_menu_item_id': null},
    );
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<List<Map<String, dynamic>>> fetchRecipesForMenu(
    String storeId,
    String menuItemId,
  ) async {
    final r = await supabase.rpc(
      'get_inventory_recipe_catalog',
      params: {'p_store_id': storeId, 'p_menu_item_id': menuItemId},
    );
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<void> upsertRecipe({
    required String storeId,
    required String menuItemId,
    required String ingredientId,
    required double quantityG,
  }) async {
    await supabase.rpc(
      'upsert_inventory_recipe_line',
      params: {
        'p_store_id': storeId,
        'p_menu_item_id': menuItemId,
        'p_ingredient_id': ingredientId,
        'p_quantity_g': quantityG,
      },
    );
  }

  Future<void> deleteRecipe(
    String menuItemId,
    String ingredientId, {
    required String storeId,
  }) async {
    await supabase
        .from('menu_recipes')
        .delete()
        .eq('menu_item_id', menuItemId)
        .eq('ingredient_id', ingredientId)
        .eq('restaurant_id', storeId);
  }

  Future<List<Map<String, dynamic>>> fetchPhysicalCounts(
    String storeId,
    String countDate,
  ) async {
    final r = await supabase.rpc(
      'get_inventory_physical_count_sheet',
      params: {'p_store_id': storeId, 'p_count_date': countDate},
    );
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<void> submitPhysicalCount({
    required String storeId,
    required String ingredientId,
    required String countDate,
    required double actualQty,
    String? note,
  }) async {
    await supabase.rpc(
      'apply_inventory_physical_count_line',
      params: {
        'p_store_id': storeId,
        'p_count_date': countDate,
        'p_ingredient_id': ingredientId,
        'p_actual_quantity_g': actualQty,
        'p_note': note,
      },
    );
  }

  Future<List<Map<String, dynamic>>> fetchTransactions({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) async {
    final r = await supabase.rpc(
      'get_inventory_transaction_visibility',
      params: {
        'p_store_id': storeId,
        'p_from': from.toUtc().toIso8601String(),
        'p_to': to.toUtc().toIso8601String(),
      },
    );
    return List<Map<String, dynamic>>.from(r as List);
  }
}

final inventoryService = InventoryService();
