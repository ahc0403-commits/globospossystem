import 'package:flutter_riverpod/flutter_riverpod.dart';

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

  Future<void> load(String restaurantId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final items = await inventoryService.fetchIngredients(restaurantId);
      state = state.copyWith(items: items, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> add({
    required String restaurantId,
    required String name,
    required String unit,
    double? currentStock,
    double? reorderPoint,
    double? costPerUnit,
    String? supplierName,
  }) async {
    await inventoryService.createIngredient(
      restaurantId: restaurantId,
      name: name,
      unit: unit,
      currentStock: currentStock,
      reorderPoint: reorderPoint,
      costPerUnit: costPerUnit,
      supplierName: supplierName,
    );
    await load(restaurantId);
  }

  Future<void> update(
    String id,
    String restaurantId,
    Map<String, dynamic> data,
  ) async {
    await inventoryService.updateIngredient(id, data);
    await load(restaurantId);
  }

  Future<void> delete(String id, String restaurantId) async {
    await inventoryService.deleteIngredient(id);
    await load(restaurantId);
  }

  Future<void> restock(
    String restaurantId,
    String ingredientId,
    double qty,
    String? note,
    String? userId,
  ) async {
    await inventoryService.restockIngredient(
      restaurantId: restaurantId,
      ingredientId: ingredientId,
      quantityG: qty,
      note: note,
      userId: userId,
    );
    await load(restaurantId);
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

  Future<void> loadAll(String restaurantId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final recipes = await inventoryService.fetchAllRecipes(restaurantId);
      final menuItems = await inventoryService.fetchMenuItems(restaurantId);
      state = state.copyWith(
        allRecipes: recipes,
        menuItems: menuItems,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> upsert({
    required String restaurantId,
    required String menuItemId,
    required String ingredientId,
    required double quantityG,
  }) async {
    await inventoryService.upsertRecipe(
      restaurantId: restaurantId,
      menuItemId: menuItemId,
      ingredientId: ingredientId,
      quantityG: quantityG,
    );
    await loadAll(restaurantId);
  }

  Future<void> delete(
    String restaurantId,
    String menuItemId,
    String ingredientId,
  ) async {
    await inventoryService.deleteRecipe(menuItemId, ingredientId);
    await loadAll(restaurantId);
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

  Future<void> load(String restaurantId, String countDate) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final counts = await inventoryService.fetchPhysicalCounts(
        restaurantId,
        countDate,
      );
      state = state.copyWith(counts: counts, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }

  Future<void> submit({
    required String restaurantId,
    required String ingredientId,
    required String countDate,
    required double actualQty,
    required double theoreticalQty,
    String? userId,
  }) async {
    state = state.copyWith(isSaving: true);
    try {
      await inventoryService.submitPhysicalCount(
        restaurantId: restaurantId,
        ingredientId: ingredientId,
        countDate: countDate,
        actualQty: actualQty,
        theoreticalQty: theoreticalQty,
        userId: userId,
      );
      await load(restaurantId, countDate);
      state = state.copyWith(isSaving: false, clearError: true);
    } catch (e) {
      state = state.copyWith(isSaving: false, error: e.toString());
    }
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
    required String restaurantId,
    required DateTime from,
    required DateTime to,
  }) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final tx = await inventoryService.fetchTransactions(
        restaurantId: restaurantId,
        from: from,
        to: to,
      );
      state = state.copyWith(transactions: tx, isLoading: false);
    } catch (e) {
      state = state.copyWith(isLoading: false, error: e.toString());
    }
  }
}

final inventoryReportProvider =
    StateNotifierProvider<InventoryReportNotifier, InventoryReportState>(
      (ref) => InventoryReportNotifier(),
    );
