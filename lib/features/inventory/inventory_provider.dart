import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/inventory_service.dart';

class IngredientState {
  final List<Map<String, dynamic>> items;
  final bool isLoading;
  final String? error;
  const IngredientState({
    this.items = const [],
    this.isLoading = false,
    this.error,
  });

  IngredientState copyWith({
    List<Map<String, dynamic>>? items,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) => IngredientState(
    items: items ?? this.items,
    isLoading: isLoading ?? this.isLoading,
    error: clearError ? null : (error ?? this.error),
  );
}

class IngredientNotifier extends StateNotifier<IngredientState> {
  IngredientNotifier() : super(const IngredientState());

  Future<void> load(String storeId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final items = await inventoryService.fetchIngredients(storeId);
      state = state.copyWith(items: items, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapIngredientError(e, 'Failed to load ingredients.'),
      );
    }
  }

  Future<bool> add({
    required String storeId,
    required String name,
    required String unit,
    double? currentStock,
    double? reorderPoint,
    double? costPerUnit,
    String? supplierName,
  }) async {
    state = state.copyWith(clearError: true);
    try {
      await inventoryService.createIngredient(
        storeId: storeId,
        name: name,
        unit: unit,
        currentStock: currentStock,
        reorderPoint: reorderPoint,
        costPerUnit: costPerUnit,
        supplierName: supplierName,
      );
      await load(storeId);
      return true;
    } catch (e) {
      state = state.copyWith(error: _mapIngredientError(e, 'Failed to add ingredient.'));
      return false;
    }
  }

  Future<bool> update(
    String id,
    String storeId,
    Map<String, dynamic> data,
  ) async {
    state = state.copyWith(clearError: true);
    try {
      await inventoryService.updateIngredient(
        id,
        data,
        storeId: storeId,
      );
      await load(storeId);
      return true;
    } catch (e) {
      state = state.copyWith(error: _mapIngredientError(e, 'Failed to update ingredient.'));
      return false;
    }
  }

  Future<void> delete(String id, String storeId) async {
    await inventoryService.deleteIngredient(id, storeId: storeId);
    await load(storeId);
  }

  Future<bool> restock(
    String storeId,
    String ingredientId,
    double qty,
    String? note,
  ) async {
    try {
      await inventoryService.restockIngredient(
        storeId: storeId,
        ingredientId: ingredientId,
        quantityG: qty,
        note: note,
      );
      await load(storeId);
      return true;
    } catch (e) {
      state = state.copyWith(error: _mapRestockWasteError(e, 'Stock-in failed.'));
      return false;
    }
  }

  Future<bool> recordWaste(
    String storeId,
    String ingredientId,
    double qty,
    String? note,
  ) async {
    try {
      await inventoryService.recordWaste(
        storeId: storeId,
        ingredientId: ingredientId,
        quantityG: qty,
        note: note,
      );
      await load(storeId);
      return true;
    } catch (e) {
      state = state.copyWith(error: _mapRestockWasteError(e, 'Waste record failed.'));
      return false;
    }
  }

  String _mapRestockWasteError(Object error, String fallback) {
    final message = error is PostgrestException
        ? (error.message)
        : error.toString();

    if (message.contains('INVENTORY_RESTOCK_FORBIDDEN') ||
        message.contains('INVENTORY_WASTE_FORBIDDEN')) {
      return 'No permission to change inventory for this store.';
    }
    if (message.contains('QUANTITY_INVALID')) {
      return 'Quantity must be greater than 0.';
    }
    if (message.contains('INGREDIENT_NOT_FOUND')) {
      return 'Ingredient not found.';
    }
    return fallback;
  }

  String _mapIngredientError(Object error, String fallback) {
    final message = error is PostgrestException
        ? (error.message)
        : error.toString();

    if (message.contains('INVENTORY_CATALOG_FORBIDDEN') ||
        message.contains('INVENTORY_ITEM_WRITE_FORBIDDEN')) {
      return 'No permission to modify ingredient catalog for this store.';
    }
    if (message.contains('INVENTORY_ITEM_NAME_REQUIRED')) {
      return 'Enter an ingredient name.';
    }
    if (message.contains('INVENTORY_ITEM_UNIT_INVALID')) {
      return 'Unit must be g, ml, or ea.';
    }
    if (message.contains('INVENTORY_ITEM_CURRENT_STOCK_INVALID') ||
        message.contains('INVENTORY_ITEM_CURRENT_STOCK_REQUIRED')) {
      return 'Current stock must be 0 or greater.';
    }
    if (message.contains('INVENTORY_ITEM_REORDER_POINT_INVALID')) {
      return 'Reorder threshold must be 0 or greater.';
    }
    if (message.contains('INVENTORY_ITEM_COST_INVALID')) {
      return 'Unit price must be 0 or greater.';
    }
    if (message.contains('INVENTORY_ITEM_NAME_DUPLICATE')) {
      return 'An ingredient with the same name already exists in this store.';
    }
    if (message.contains('INVENTORY_ITEM_PATCH_INVALID') ||
        message.contains('INVENTORY_ITEM_PATCH_EMPTY') ||
        message.contains('INVENTORY_ITEM_PATCH_UNSUPPORTED')) {
      return 'Only editable ingredient items can be changed.';
    }
    if (message.contains('INVENTORY_ITEM_NOT_FOUND')) {
      return 'Reload ingredients and try again.';
    }

    return fallback;
  }
}

final ingredientProvider =
    StateNotifierProvider<IngredientNotifier, IngredientState>(
      (ref) => IngredientNotifier(),
    );

class RecipeState {
  final List<Map<String, dynamic>> allRecipes;
  final List<Map<String, dynamic>> menuItems;
  final bool isLoading;
  final String? error;
  const RecipeState({
    this.allRecipes = const [],
    this.menuItems = const [],
    this.isLoading = false,
    this.error,
  });

  RecipeState copyWith({
    List<Map<String, dynamic>>? allRecipes,
    List<Map<String, dynamic>>? menuItems,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) => RecipeState(
    allRecipes: allRecipes ?? this.allRecipes,
    menuItems: menuItems ?? this.menuItems,
    isLoading: isLoading ?? this.isLoading,
    error: clearError ? null : (error ?? this.error),
  );
}

class RecipeNotifier extends StateNotifier<RecipeState> {
  RecipeNotifier() : super(const RecipeState());

  Future<void> loadAll(String storeId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final recipes = await inventoryService.fetchAllRecipes(storeId);
      final menuItems = await inventoryService.fetchMenuItems(storeId);
      state = state.copyWith(
        allRecipes: recipes,
        menuItems: menuItems,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapRecipeError(e, 'Failed to load recipe mappings.'),
      );
    }
  }

  Future<bool> upsert({
    required String storeId,
    required String menuItemId,
    required String ingredientId,
    required double quantityG,
  }) async {
    state = state.copyWith(clearError: true);
    try {
      await inventoryService.upsertRecipe(
        storeId: storeId,
        menuItemId: menuItemId,
        ingredientId: ingredientId,
        quantityG: quantityG,
      );
      await loadAll(storeId);
      return true;
    } catch (e) {
      state = state.copyWith(error: _mapRecipeError(e, 'Failed to save recipe mapping.'));
      return false;
    }
  }

  Future<void> delete(
    String storeId,
    String menuItemId,
    String ingredientId,
  ) async {
    await inventoryService.deleteRecipe(
      menuItemId,
      ingredientId,
      storeId: storeId,
    );
    await loadAll(storeId);
  }

  String _mapRecipeError(Object error, String fallback) {
    final message = error is PostgrestException
        ? (error.message)
        : error.toString();

    if (message.contains('INVENTORY_RECIPE_FORBIDDEN') ||
        message.contains('INVENTORY_RECIPE_WRITE_FORBIDDEN')) {
      return 'No permission to modify recipes for this store.';
    }
    if (message.contains('INVENTORY_RECIPE_MENU_ITEM_REQUIRED') ||
        message.contains('INVENTORY_RECIPE_MENU_ITEM_NOT_FOUND')) {
      return 'Select a valid menu.';
    }
    if (message.contains('INVENTORY_RECIPE_INGREDIENT_REQUIRED') ||
        message.contains('INVENTORY_RECIPE_INGREDIENT_NOT_FOUND')) {
      return 'Select a valid ingredient.';
    }
    if (message.contains('INVENTORY_RECIPE_QUANTITY_INVALID')) {
      return 'Usage (g) must be greater than 0.';
    }
    if (message.contains('INVENTORY_RECIPE_INGREDIENT_UNIT_UNSUPPORTED')) {
      return 'In v1, only ingredients with unit g can be linked to recipes.';
    }

    return fallback;
  }
}

final recipeProvider = StateNotifierProvider<RecipeNotifier, RecipeState>(
  (ref) => RecipeNotifier(),
);

class PhysicalCountState {
  final List<Map<String, dynamic>> counts;
  final bool isLoading;
  final bool isSaving;
  final String? error;
  const PhysicalCountState({
    this.counts = const [],
    this.isLoading = false,
    this.isSaving = false,
    this.error,
  });

  PhysicalCountState copyWith({
    List<Map<String, dynamic>>? counts,
    bool? isLoading,
    bool? isSaving,
    String? error,
    bool clearError = false,
  }) => PhysicalCountState(
    counts: counts ?? this.counts,
    isLoading: isLoading ?? this.isLoading,
    isSaving: isSaving ?? this.isSaving,
    error: clearError ? null : (error ?? this.error),
  );
}

class PhysicalCountNotifier extends StateNotifier<PhysicalCountState> {
  PhysicalCountNotifier() : super(const PhysicalCountState());

  Future<void> load(String storeId, String countDate) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final counts = await inventoryService.fetchPhysicalCounts(
        storeId,
        countDate,
      );
      state = state.copyWith(counts: counts, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapPhysicalCountError(e, 'Failed to load physical count sheet.'),
      );
    }
  }

  Future<void> submit({
    required String storeId,
    required String ingredientId,
    required String countDate,
    required double actualQty,
    String? note,
  }) async {
    state = state.copyWith(isSaving: true);
    try {
      await inventoryService.submitPhysicalCount(
        storeId: storeId,
        ingredientId: ingredientId,
        countDate: countDate,
        actualQty: actualQty,
        note: note,
      );
      await load(storeId, countDate);
      state = state.copyWith(isSaving: false, clearError: true);
    } catch (e) {
      state = state.copyWith(
        isSaving: false,
        error: _mapPhysicalCountError(e, 'Failed to apply physical count.'),
      );
    }
  }

  String _mapPhysicalCountError(Object error, String fallback) {
    final message = error is PostgrestException
        ? (error.message)
        : error.toString();

    if (message.contains('INVENTORY_PHYSICAL_COUNT_FORBIDDEN') ||
        message.contains('INVENTORY_PHYSICAL_COUNT_WRITE_FORBIDDEN')) {
      return 'No permission to apply physical count for this store.';
    }
    if (message.contains('INVENTORY_PHYSICAL_COUNT_DATE_REQUIRED')) {
      return 'Check the physical count reference date.';
    }
    if (message.contains('INVENTORY_PHYSICAL_COUNT_INGREDIENT_REQUIRED') ||
        message.contains('INVENTORY_PHYSICAL_COUNT_INGREDIENT_NOT_FOUND')) {
      return 'Select a valid ingredient.';
    }
    if (message.contains('INVENTORY_PHYSICAL_COUNT_ACTUAL_INVALID')) {
      return 'Actual stock must be 0 or greater.';
    }

    return fallback;
  }
}

final physicalCountProvider =
    StateNotifierProvider<PhysicalCountNotifier, PhysicalCountState>(
      (ref) => PhysicalCountNotifier(),
    );

class InventoryReportState {
  final List<Map<String, dynamic>> transactions;
  final bool isLoading;
  final String? error;
  const InventoryReportState({
    this.transactions = const [],
    this.isLoading = false,
    this.error,
  });

  InventoryReportState copyWith({
    List<Map<String, dynamic>>? transactions,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) => InventoryReportState(
    transactions: transactions ?? this.transactions,
    isLoading: isLoading ?? this.isLoading,
    error: clearError ? null : (error ?? this.error),
  );
}

class InventoryReportNotifier extends StateNotifier<InventoryReportState> {
  InventoryReportNotifier() : super(const InventoryReportState());

  Future<void> load({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final tx = await inventoryService.fetchTransactions(
        storeId: storeId,
        from: from,
        to: to,
      );
      state = state.copyWith(transactions: tx, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapInventoryReportError(e),
      );
    }
  }

  String _mapInventoryReportError(Object error) {
    final fallback = 'Failed to load inventory transactions.';
    final message = error.toString();

    if (message.contains('INVENTORY_TRANSACTION_VISIBILITY_FORBIDDEN')) {
      return 'No permission to view inventory transactions for this store.';
    }
    if (message.contains('INVENTORY_TRANSACTION_VISIBILITY_RANGE_REQUIRED')) {
      return 'Re-check the query period.';
    }
    if (message.contains('INVENTORY_TRANSACTION_VISIBILITY_RANGE_INVALID')) {
      return 'Check the start and end date order.';
    }

    return fallback;
  }
}

final inventoryReportProvider =
    StateNotifierProvider<InventoryReportNotifier, InventoryReportState>(
      (ref) => InventoryReportNotifier(),
    );
