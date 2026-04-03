import '../../main.dart';

class InventoryService {
  Future<List<Map<String, dynamic>>> fetchIngredients(
    String restaurantId,
  ) async {
    final r = await supabase
        .from('inventory_items')
        .select()
        .eq('restaurant_id', restaurantId)
        .order('name');
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<void> createIngredient({
    required String restaurantId,
    required String name,
    required String unit,
    double? currentStock,
    double? reorderPoint,
    double? costPerUnit,
    String? supplierName,
  }) async {
    await supabase.from('inventory_items').insert({
      'restaurant_id': restaurantId,
      'name': name,
      'unit': unit,
      'quantity': 0,
      if (currentStock != null) 'current_stock': currentStock,
      if (reorderPoint != null) 'reorder_point': reorderPoint,
      if (costPerUnit != null) 'cost_per_unit': costPerUnit,
      if (supplierName != null) 'supplier_name': supplierName,
    });
  }

  Future<void> updateIngredient(String id, Map<String, dynamic> data) async {
    await supabase.from('inventory_items').update(data).eq('id', id);
  }

  Future<void> deleteIngredient(String id) async {
    await supabase.from('inventory_items').delete().eq('id', id);
  }

  Future<void> restockIngredient({
    required String restaurantId,
    required String ingredientId,
    required double quantityG,
    String? note,
    String? userId,
  }) async {
    final current = await supabase
        .from('inventory_items')
        .select('current_stock')
        .eq('id', ingredientId)
        .single();
    final newStock =
        ((current['current_stock'] as num?)?.toDouble() ?? 0) + quantityG;
    await supabase
        .from('inventory_items')
        .update({
          'current_stock': newStock,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', ingredientId);

    await supabase.from('inventory_transactions').insert({
      'restaurant_id': restaurantId,
      'ingredient_id': ingredientId,
      'transaction_type': 'restock',
      'quantity_g': quantityG,
      'reference_type': 'manual',
      'note': note,
      'created_by': userId,
    });
  }

  Future<List<Map<String, dynamic>>> fetchMenuItems(String restaurantId) async {
    final r = await supabase
        .from('menu_items')
        .select('id, name, sort_order')
        .eq('restaurant_id', restaurantId)
        .order('sort_order');
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<List<Map<String, dynamic>>> fetchAllRecipes(
    String restaurantId,
  ) async {
    final r = await supabase
        .from('menu_recipes')
        .select('*, menu_items(id, name), inventory_items(id, name, unit)')
        .eq('restaurant_id', restaurantId);
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<List<Map<String, dynamic>>> fetchRecipesForMenu(
    String menuItemId,
  ) async {
    final r = await supabase
        .from('menu_recipes')
        .select('*, inventory_items(id, name, unit)')
        .eq('menu_item_id', menuItemId);
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<void> upsertRecipe({
    required String restaurantId,
    required String menuItemId,
    required String ingredientId,
    required double quantityG,
  }) async {
    await supabase.from('menu_recipes').upsert({
      'restaurant_id': restaurantId,
      'menu_item_id': menuItemId,
      'ingredient_id': ingredientId,
      'quantity_g': quantityG,
    }, onConflict: 'menu_item_id,ingredient_id');
  }

  Future<void> deleteRecipe(String menuItemId, String ingredientId) async {
    await supabase
        .from('menu_recipes')
        .delete()
        .eq('menu_item_id', menuItemId)
        .eq('ingredient_id', ingredientId);
  }

  Future<List<Map<String, dynamic>>> fetchPhysicalCounts(
    String restaurantId,
    String countDate,
  ) async {
    final r = await supabase
        .from('inventory_physical_counts')
        .select('*, inventory_items(id, name, unit)')
        .eq('restaurant_id', restaurantId)
        .eq('count_date', countDate);
    return List<Map<String, dynamic>>.from(r as List);
  }

  Future<void> submitPhysicalCount({
    required String restaurantId,
    required String ingredientId,
    required String countDate,
    required double actualQty,
    required double theoreticalQty,
    String? userId,
  }) async {
    final variance = actualQty - theoreticalQty;
    await supabase.from('inventory_physical_counts').upsert({
      'restaurant_id': restaurantId,
      'ingredient_id': ingredientId,
      'count_date': countDate,
      'actual_quantity_g': actualQty,
      'theoretical_quantity_g': theoreticalQty,
      'variance_g': variance,
      'counted_by': userId,
    }, onConflict: 'ingredient_id,count_date');

    await supabase
        .from('inventory_items')
        .update({
          'current_stock': actualQty,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', ingredientId);

    await supabase.from('inventory_transactions').insert({
      'restaurant_id': restaurantId,
      'ingredient_id': ingredientId,
      'transaction_type': 'adjust',
      'quantity_g': variance,
      'reference_type': 'physical_count',
      'note': '실재고 실사 ($countDate)',
      'created_by': userId,
    });
  }

  Future<List<Map<String, dynamic>>> fetchTransactions({
    required String restaurantId,
    required DateTime from,
    required DateTime to,
  }) async {
    final r = await supabase
        .from('inventory_transactions')
        .select('*, inventory_items(id, name, unit)')
        .eq('restaurant_id', restaurantId)
        .gte('created_at', from.toIso8601String())
        .lte('created_at', to.toIso8601String())
        .order('created_at', ascending: false);
    return List<Map<String, dynamic>>.from(r as List);
  }
}

final inventoryService = InventoryService();
