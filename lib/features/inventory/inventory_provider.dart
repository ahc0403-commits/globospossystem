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
      state = state.copyWith(
        error: _mapIngredientError(e, 'Failed to add ingredient.'),
      );
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
      await inventoryService.updateIngredient(id, data, storeId: storeId);
      await load(storeId);
      return true;
    } catch (e) {
      state = state.copyWith(
        error: _mapIngredientError(e, 'Failed to update ingredient.'),
      );
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
      state = state.copyWith(
        error: _mapRestockWasteError(e, 'Stock-in failed.'),
      );
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
      state = state.copyWith(
        error: _mapRestockWasteError(e, 'Waste record failed.'),
      );
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
      state = state.copyWith(
        error: _mapRecipeError(e, 'Failed to save recipe mapping.'),
      );
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
        error: _mapPhysicalCountError(
          e,
          'Failed to load physical count sheet.',
        ),
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

class InventoryPurchaseOverviewState {
  final Map<String, dynamic>? dashboard;
  final bool isLoading;
  final String? error;

  const InventoryPurchaseOverviewState({
    this.dashboard,
    this.isLoading = false,
    this.error,
  });

  InventoryPurchaseOverviewState copyWith({
    Map<String, dynamic>? dashboard,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) => InventoryPurchaseOverviewState(
    dashboard: dashboard ?? this.dashboard,
    isLoading: isLoading ?? this.isLoading,
    error: clearError ? null : (error ?? this.error),
  );
}

class InventoryPurchaseOverviewNotifier
    extends StateNotifier<InventoryPurchaseOverviewState> {
  InventoryPurchaseOverviewNotifier()
    : super(const InventoryPurchaseOverviewState());

  Future<void> load(String storeId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final dashboard = await inventoryService.fetchInventoryPurchaseDashboard(
        storeId: storeId,
      );
      state = state.copyWith(dashboard: dashboard, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapInventoryPurchaseOverviewError(e),
      );
    }
  }

  String _mapInventoryPurchaseOverviewError(Object error) {
    final fallback = 'Failed to load purchase overview.';
    final message = error.toString();

    if (message.contains('INVENTORY_PURCHASE_FORBIDDEN')) {
      return 'No permission to view inventory purchase overview for this store.';
    }

    return fallback;
  }
}

final inventoryPurchaseOverviewProvider =
    StateNotifierProvider<
      InventoryPurchaseOverviewNotifier,
      InventoryPurchaseOverviewState
    >((ref) => InventoryPurchaseOverviewNotifier());

class InventoryPurchaseRecommendationRunState {
  final bool isRunning;
  final String? error;
  final String? lastRunId;
  final double? lastTargetStockDays;
  final String? lastAsOfDate;

  const InventoryPurchaseRecommendationRunState({
    this.isRunning = false,
    this.error,
    this.lastRunId,
    this.lastTargetStockDays,
    this.lastAsOfDate,
  });

  InventoryPurchaseRecommendationRunState copyWith({
    bool? isRunning,
    String? error,
    bool clearError = false,
    String? lastRunId,
    double? lastTargetStockDays,
    String? lastAsOfDate,
  }) => InventoryPurchaseRecommendationRunState(
    isRunning: isRunning ?? this.isRunning,
    error: clearError ? null : (error ?? this.error),
    lastRunId: lastRunId ?? this.lastRunId,
    lastTargetStockDays: lastTargetStockDays ?? this.lastTargetStockDays,
    lastAsOfDate: lastAsOfDate ?? this.lastAsOfDate,
  );
}

class InventoryPurchaseRecommendationRunNotifier
    extends StateNotifier<InventoryPurchaseRecommendationRunState> {
  InventoryPurchaseRecommendationRunNotifier()
    : super(const InventoryPurchaseRecommendationRunState());

  Future<bool> run({
    required String storeId,
    required double targetStockDays,
    required DateTime asOfDate,
  }) async {
    state = state.copyWith(isRunning: true, clearError: true);
    try {
      final runId = await inventoryService.runInventoryPurchaseRecommendation(
        storeId: storeId,
        targetStockDays: targetStockDays,
        asOfDate: asOfDate,
      );
      state = state.copyWith(
        isRunning: false,
        lastRunId: runId,
        lastTargetStockDays: targetStockDays,
        lastAsOfDate: asOfDate.toIso8601String().split('T').first,
      );
      return true;
    } catch (e) {
      state = state.copyWith(
        isRunning: false,
        error: _mapInventoryPurchaseRecommendationError(e),
      );
      return false;
    }
  }

  String _mapInventoryPurchaseRecommendationError(Object error) {
    final fallback = 'Failed to generate recommendation snapshot.';
    final message = error.toString();

    if (message.contains('INVENTORY_PURCHASE_FORBIDDEN')) {
      return 'No permission to generate a purchase recommendation for this store.';
    }
    if (message.contains('INVENTORY_PURCHASE_TARGET_DAYS_INVALID')) {
      return 'Target stock days must be greater than zero.';
    }

    return fallback;
  }
}

final inventoryPurchaseRecommendationRunProvider =
    StateNotifierProvider<
      InventoryPurchaseRecommendationRunNotifier,
      InventoryPurchaseRecommendationRunState
    >((ref) => InventoryPurchaseRecommendationRunNotifier());

class InventoryPurchaseRecommendationSnapshotState {
  final Map<String, dynamic>? run;
  final List<Map<String, dynamic>> lines;
  final bool isLoading;
  final String? error;

  const InventoryPurchaseRecommendationSnapshotState({
    this.run,
    this.lines = const [],
    this.isLoading = false,
    this.error,
  });

  InventoryPurchaseRecommendationSnapshotState copyWith({
    Map<String, dynamic>? run,
    List<Map<String, dynamic>>? lines,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) => InventoryPurchaseRecommendationSnapshotState(
    run: run ?? this.run,
    lines: lines ?? this.lines,
    isLoading: isLoading ?? this.isLoading,
    error: clearError ? null : (error ?? this.error),
  );
}

class InventoryPurchaseRecommendationSnapshotNotifier
    extends StateNotifier<InventoryPurchaseRecommendationSnapshotState> {
  InventoryPurchaseRecommendationSnapshotNotifier()
    : super(const InventoryPurchaseRecommendationSnapshotState());

  Future<void> loadLatest(String storeId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final run = await inventoryService
          .fetchLatestInventoryPurchaseRecommendationRun(storeId: storeId);
      if (run == null) {
        state = state.copyWith(run: null, lines: const [], isLoading: false);
        return;
      }

      final lines = await inventoryService
          .fetchInventoryPurchaseRecommendationLines(
            runId: run['id'].toString(),
          );
      state = state.copyWith(run: run, lines: lines, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapInventoryPurchaseRecommendationSnapshotError(e),
      );
    }
  }

  String _mapInventoryPurchaseRecommendationSnapshotError(Object error) {
    final fallback = 'Failed to load recommendation snapshot detail.';
    final message = error.toString();

    if (message.contains('INVENTORY_PURCHASE_FORBIDDEN')) {
      return 'No permission to view recommendation snapshots for this store.';
    }

    return fallback;
  }
}

final inventoryPurchaseRecommendationSnapshotProvider =
    StateNotifierProvider<
      InventoryPurchaseRecommendationSnapshotNotifier,
      InventoryPurchaseRecommendationSnapshotState
    >((ref) => InventoryPurchaseRecommendationSnapshotNotifier());

class InventoryPurchaseOrderCreationState {
  final bool isCreating;
  final String? error;
  final List<Map<String, dynamic>> createdOrders;
  final String? sourceRunId;

  const InventoryPurchaseOrderCreationState({
    this.isCreating = false,
    this.error,
    this.createdOrders = const [],
    this.sourceRunId,
  });

  InventoryPurchaseOrderCreationState copyWith({
    bool? isCreating,
    String? error,
    bool clearError = false,
    List<Map<String, dynamic>>? createdOrders,
    String? sourceRunId,
  }) => InventoryPurchaseOrderCreationState(
    isCreating: isCreating ?? this.isCreating,
    error: clearError ? null : (error ?? this.error),
    createdOrders: createdOrders ?? this.createdOrders,
    sourceRunId: sourceRunId ?? this.sourceRunId,
  );
}

class InventoryPurchaseOrderCreationNotifier
    extends StateNotifier<InventoryPurchaseOrderCreationState> {
  InventoryPurchaseOrderCreationNotifier()
    : super(const InventoryPurchaseOrderCreationState());

  Future<bool> createFromRecommendation({
    required String runId,
    DateTime? requestedDeliveryDate,
  }) async {
    state = state.copyWith(isCreating: true, clearError: true);
    try {
      final orders = await inventoryService
          .createPurchaseOrdersFromRecommendation(
            runId: runId,
            requestedDeliveryDate: requestedDeliveryDate,
          );
      state = state.copyWith(
        isCreating: false,
        createdOrders: orders,
        sourceRunId: runId,
      );
      return true;
    } catch (e) {
      state = state.copyWith(
        isCreating: false,
        error: _mapInventoryPurchaseOrderCreationError(e),
      );
      return false;
    }
  }

  String _mapInventoryPurchaseOrderCreationError(Object error) {
    final fallback = 'Failed to create supplier-grouped purchase orders.';
    final message = error.toString();

    if (message.contains('INVENTORY_RECOMMENDATION_RUN_NOT_FOUND')) {
      return 'The selected recommendation snapshot is no longer available.';
    }
    if (message.contains('INVENTORY_PURCHASE_FORBIDDEN')) {
      return 'No permission to create purchase orders for this store.';
    }

    return fallback;
  }
}

final inventoryPurchaseOrderCreationProvider =
    StateNotifierProvider<
      InventoryPurchaseOrderCreationNotifier,
      InventoryPurchaseOrderCreationState
    >((ref) => InventoryPurchaseOrderCreationNotifier());

class InventoryPurchaseOrderSummaryState {
  final List<Map<String, dynamic>> orders;
  final bool isLoading;
  final String? error;

  const InventoryPurchaseOrderSummaryState({
    this.orders = const [],
    this.isLoading = false,
    this.error,
  });

  InventoryPurchaseOrderSummaryState copyWith({
    List<Map<String, dynamic>>? orders,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) => InventoryPurchaseOrderSummaryState(
    orders: orders ?? this.orders,
    isLoading: isLoading ?? this.isLoading,
    error: clearError ? null : (error ?? this.error),
  );
}

class InventoryPurchaseOrderSummaryNotifier
    extends StateNotifier<InventoryPurchaseOrderSummaryState> {
  InventoryPurchaseOrderSummaryNotifier()
    : super(const InventoryPurchaseOrderSummaryState());

  Future<void> load(String storeId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final orders = await inventoryService.fetchRecentInventoryPurchaseOrders(
        storeId: storeId,
      );
      state = state.copyWith(orders: orders, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapInventoryPurchaseOrderSummaryError(e),
      );
    }
  }

  String _mapInventoryPurchaseOrderSummaryError(Object error) {
    final fallback = 'Failed to load recent purchase orders.';
    final message = error.toString();

    if (message.contains('INVENTORY_PURCHASE_FORBIDDEN')) {
      return 'No permission to view purchase orders for this store.';
    }

    return fallback;
  }
}

final inventoryPurchaseOrderSummaryProvider =
    StateNotifierProvider<
      InventoryPurchaseOrderSummaryNotifier,
      InventoryPurchaseOrderSummaryState
    >((ref) => InventoryPurchaseOrderSummaryNotifier());

class InventoryPurchaseOrderDetailState {
  final String? selectedOrderId;
  final Map<String, dynamic>? order;
  final List<Map<String, dynamic>> lines;
  final List<Map<String, dynamic>> receipts;
  final bool isLoading;
  final String? error;

  const InventoryPurchaseOrderDetailState({
    this.selectedOrderId,
    this.order,
    this.lines = const [],
    this.receipts = const [],
    this.isLoading = false,
    this.error,
  });

  InventoryPurchaseOrderDetailState copyWith({
    String? selectedOrderId,
    Map<String, dynamic>? order,
    List<Map<String, dynamic>>? lines,
    List<Map<String, dynamic>>? receipts,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) => InventoryPurchaseOrderDetailState(
    selectedOrderId: selectedOrderId ?? this.selectedOrderId,
    order: order ?? this.order,
    lines: lines ?? this.lines,
    receipts: receipts ?? this.receipts,
    isLoading: isLoading ?? this.isLoading,
    error: clearError ? null : (error ?? this.error),
  );
}

class InventoryPurchaseOrderDetailNotifier
    extends StateNotifier<InventoryPurchaseOrderDetailState> {
  InventoryPurchaseOrderDetailNotifier()
    : super(const InventoryPurchaseOrderDetailState());

  Future<void> load(String orderId) async {
    state = state.copyWith(
      selectedOrderId: orderId,
      isLoading: true,
      clearError: true,
    );
    try {
      final detail = await inventoryService.fetchInventoryPurchaseOrderDetail(
        purchaseOrderId: orderId,
      );
      if (detail == null) {
        state = state.copyWith(
          order: null,
          lines: const [],
          receipts: const [],
          isLoading: false,
          error: 'The selected purchase order is no longer available.',
        );
        return;
      }

      state = state.copyWith(
        order: Map<String, dynamic>.from(detail['order'] as Map),
        lines: List<Map<String, dynamic>>.from(detail['lines'] as List),
        receipts: List<Map<String, dynamic>>.from(detail['receipts'] as List),
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapInventoryPurchaseOrderDetailError(e),
      );
    }
  }

  void clear() {
    state = const InventoryPurchaseOrderDetailState();
  }

  String _mapInventoryPurchaseOrderDetailError(Object error) {
    final fallback = 'Failed to load purchase order detail.';
    final message = error.toString();

    if (message.contains('INVENTORY_PURCHASE_FORBIDDEN')) {
      return 'No permission to view this purchase order detail.';
    }

    return fallback;
  }
}

final inventoryPurchaseOrderDetailProvider =
    StateNotifierProvider<
      InventoryPurchaseOrderDetailNotifier,
      InventoryPurchaseOrderDetailState
    >((ref) => InventoryPurchaseOrderDetailNotifier());

enum InventoryPurchaseRuntimeResultKind {
  idle,
  success,
  failure,
  blocked,
  cancelled,
}

class InventoryPurchaseRuntimeResult {
  final InventoryPurchaseRuntimeResultKind kind;
  final String title;
  final String message;

  const InventoryPurchaseRuntimeResult({
    required this.kind,
    required this.title,
    required this.message,
  });
}

class InventoryPurchaseRuntimeClosureSnapshot {
  final String approvalStateLabel;
  final String receivingStateLabel;
  final String handoffTarget;
  final String operatorSummary;
  final String lastRuntimeStateLabel;
  final InventoryPurchaseRuntimeResult? lastRuntimeResult;
  final List<String> blockedReasons;
  final bool canCheckApproval;
  final bool canConfirmReceipt;

  const InventoryPurchaseRuntimeClosureSnapshot({
    required this.approvalStateLabel,
    required this.receivingStateLabel,
    required this.handoffTarget,
    required this.operatorSummary,
    required this.lastRuntimeStateLabel,
    required this.lastRuntimeResult,
    required this.blockedReasons,
    required this.canCheckApproval,
    required this.canConfirmReceipt,
  });
}

class InventoryPurchaseOperatingSummary {
  final String recommendationRuntimeStateLabel;
  final String latestSnapshotStateLabel;
  final String purchaseOrderCreationReadinessLabel;
  final String approvalHandoffReadinessLabel;
  final String receivingReadinessLabel;
  final String selectedPurchaseOrderRuntimeLabel;
  final String nextOperatorAction;
  final String operatingNarrative;
  final String handoffTarget;
  final List<String> blockedReasons;
  final int visibleRecommendationLineCount;
  final int visiblePurchaseOrderCount;
  final int visibleBlockedReasonCount;
  final bool hasSelectedPurchaseOrder;
  final bool canConfirmReceipt;

  const InventoryPurchaseOperatingSummary({
    required this.recommendationRuntimeStateLabel,
    required this.latestSnapshotStateLabel,
    required this.purchaseOrderCreationReadinessLabel,
    required this.approvalHandoffReadinessLabel,
    required this.receivingReadinessLabel,
    required this.selectedPurchaseOrderRuntimeLabel,
    required this.nextOperatorAction,
    required this.operatingNarrative,
    required this.handoffTarget,
    required this.blockedReasons,
    required this.visibleRecommendationLineCount,
    required this.visiblePurchaseOrderCount,
    required this.visibleBlockedReasonCount,
    required this.hasSelectedPurchaseOrder,
    required this.canConfirmReceipt,
  });
}

InventoryPurchaseRuntimeClosureSnapshot
buildInventoryPurchaseRuntimeClosureSnapshot({
  required Map<String, dynamic>? order,
  required InventoryPurchaseApprovalRuntimeState approvalRuntime,
  required InventoryPurchaseReceivingRuntimeState receivingRuntime,
  required int blockedLineCount,
  required int pendingLineCount,
  required int attentionLineCount,
}) {
  final status = order?['status']?.toString() ?? 'unknown';
  final remainingBase =
      (order?['total_remaining_quantity_base'] as num?)?.toDouble() ?? 0;
  final hasApprovedTruth =
      status == 'office_approved' ||
      status == 'ordered' ||
      status == 'partially_received' ||
      status == 'received';
  final canConfirmReceipt =
      remainingBase > 0 &&
      (status == 'office_approved' ||
          status == 'ordered' ||
          status == 'partially_received') &&
      !receivingRuntime.isSubmitting;
  final lastRuntimeResult = receivingRuntime.result ?? approvalRuntime.result;

  final approvalStateLabel = switch (status) {
    'submitted' || 'office_returned' => 'Ready to approve',
    'office_approved' ||
    'ordered' ||
    'partially_received' ||
    'received' => 'Approved',
    'office_rejected' || 'cancelled' => 'Approval blocked',
    _ => 'Approval pending',
  };
  final receivingStateLabel = switch (status) {
    'received' => 'Received / closed',
    'office_approved' ||
    'ordered' ||
    'partially_received' when remainingBase > 0 => 'Ready to receive',
    'office_approved' ||
    'ordered' ||
    'partially_received' => 'Received / closed',
    _ => 'Receiving blocked',
  };
  final handoffTarget = switch (status) {
    'submitted' || 'office_returned' => 'Handoff target Office approval queue',
    'office_approved' ||
    'ordered' ||
    'partially_received' => 'Handoff target POS receiving contract',
    'received' => 'Handoff target Verification only',
    'office_rejected' => 'Handoff target Office rejection follow-up',
    'cancelled' => 'Handoff target Closed cancellation record',
    _ => 'Handoff target Runtime boundary review',
  };

  final blockedReasons = <String>[];
  if (order == null) {
    blockedReasons.add(
      'Load a tracked purchase order first so POS can evaluate approval handoff and receiving readiness.',
    );
  } else {
    if (status == 'submitted' || status == 'office_returned') {
      blockedReasons.add(
        'Office approval truth is still missing, so receiving stays blocked until the Office-owned gate is complete.',
      );
    }
    if (status == 'office_rejected') {
      blockedReasons.add(
        'Office rejected the purchase order, so POS must keep both approval execution and receiving blocked.',
      );
    }
    if (status == 'cancelled') {
      blockedReasons.add(
        'Backend truth already cancelled this purchase order, so runtime actions stay unavailable.',
      );
    }
    if (remainingBase <= 0 && hasApprovedTruth) {
      blockedReasons.add(
        'No remaining inbound quantity is visible, so POS keeps the order in verification-only mode.',
      );
    }
    if (blockedLineCount > 0) {
      blockedReasons.add(
        '$blockedLineCount blocker line(s) still require supplier or arrival follow-up before operators should treat the order as stable.',
      );
    }
    if (attentionLineCount > 0) {
      blockedReasons.add(
        '$attentionLineCount high-attention line(s) still carry supplier, price, or lead-time risk that operators should review first.',
      );
    }
    if (pendingLineCount > 0 && !canConfirmReceipt && status != 'received') {
      blockedReasons.add(
        '$pendingLineCount line(s) remain pending while the current backend status does not allow POS receipt confirmation yet.',
      );
    }
  }

  final operatorSummary = switch (status) {
    'submitted' || 'office_returned' =>
      'POS can prepare the purchase order for handoff, but Office still owns approval execution and the backend does not yet allow receipt confirmation.',
    'office_approved' || 'ordered' || 'partially_received'
        when remainingBase > 0 =>
      'Approval truth already exists, so POS can use the tracked receipt contract after physical inbound verification while keeping approval execution outside POS.',
    'received' =>
      'Runtime closure is complete for this order. Operators can verify receipts, line context, and stock-facing outcomes without opening more runtime actions.',
    'office_rejected' =>
      'This order is blocked by Office review outcome, so POS keeps only the visibility, blocker, and handoff narrative available.',
    'cancelled' =>
      'This order is closed by cancellation, so POS keeps the final runtime boundary visible without opening approval or receiving paths.',
    _ =>
      'POS keeps the runtime boundary visible, but the current backend state still needs review before any operator action becomes meaningful.',
  };

  final lastRuntimeStateLabel = lastRuntimeResult == null
      ? 'Last runtime state none yet'
      : 'Last runtime state ${lastRuntimeResult.title}';

  return InventoryPurchaseRuntimeClosureSnapshot(
    approvalStateLabel: approvalStateLabel,
    receivingStateLabel: receivingStateLabel,
    handoffTarget: handoffTarget,
    operatorSummary: operatorSummary,
    lastRuntimeStateLabel: lastRuntimeStateLabel,
    lastRuntimeResult: lastRuntimeResult,
    blockedReasons: blockedReasons,
    canCheckApproval: order != null && !approvalRuntime.isEvaluating,
    canConfirmReceipt: canConfirmReceipt,
  );
}

InventoryPurchaseOperatingSummary buildInventoryPurchaseOperatingSummary({
  required InventoryPurchaseOverviewState overview,
  required InventoryPurchaseRecommendationRunState recommendationRun,
  required InventoryPurchaseRecommendationSnapshotState recommendationSnapshot,
  required InventoryPurchaseOrderCreationState orderCreation,
  required InventoryPurchaseOrderSummaryState orderSummary,
  required InventoryPurchaseOrderDetailState orderDetail,
  required InventoryPurchaseRuntimeClosureSnapshot runtimeClosure,
}) {
  final recommendationRuntimeStateLabel = recommendationRun.isRunning
      ? 'Recommendation running'
      : recommendationRun.error != null
      ? 'Recommendation blocked'
      : recommendationRun.lastRunId != null
      ? 'Recommendation ready'
      : 'Recommendation idle';

  final latestSnapshotStateLabel = recommendationSnapshot.isLoading
      ? 'Latest snapshot loading'
      : recommendationSnapshot.error != null
      ? 'Latest snapshot blocked'
      : recommendationSnapshot.run == null
      ? 'Latest snapshot missing'
      : recommendationSnapshot.lines.isEmpty
      ? 'Latest snapshot empty'
      : 'Latest snapshot visible';

  final purchaseOrderCreationReadinessLabel = orderCreation.isCreating
      ? 'PO creation running'
      : orderCreation.error != null
      ? 'PO creation blocked'
      : recommendationSnapshot.run == null
      ? 'PO creation waiting snapshot'
      : recommendationSnapshot.lines.isEmpty
      ? 'PO creation waiting supplier-qualified lines'
      : 'PO creation ready';

  final approvalHandoffReadinessLabel = orderDetail.order == null
      ? 'Approval handoff waiting selected PO'
      : runtimeClosure.approvalStateLabel;
  final receivingReadinessLabel = orderDetail.order == null
      ? 'Receiving waiting selected PO'
      : runtimeClosure.receivingStateLabel;
  final selectedPurchaseOrderRuntimeLabel = orderDetail.order == null
      ? 'Selected PO runtime pending'
      : runtimeClosure.lastRuntimeStateLabel;

  final blockedReasons = <String>[
    if (overview.error != null) overview.error!,
    if (recommendationRun.error != null) recommendationRun.error!,
    if (recommendationSnapshot.error != null) recommendationSnapshot.error!,
    if (orderCreation.error != null) orderCreation.error!,
    if (orderSummary.error != null) orderSummary.error!,
    if (orderDetail.error != null) orderDetail.error!,
    if (recommendationSnapshot.run == null)
      'No tracked recommendation snapshot is visible yet, so downstream purchase-order preparation still depends on a new snapshot run.',
    if (recommendationSnapshot.run != null &&
        recommendationSnapshot.lines.isEmpty)
      'The latest recommendation snapshot is visible, but no supplier-qualified lines are currently available for purchase-order preparation.',
    if (orderSummary.orders.isNotEmpty && orderDetail.order == null)
      'Recent purchase orders are visible, but operators still need to select one to inspect the runtime closure and receiving path.',
    ...runtimeClosure.blockedReasons,
  ].where((reason) => reason.trim().isNotEmpty).toSet().toList();

  final nextOperatorAction = () {
    if (overview.dashboard == null && !overview.isLoading) {
      return 'Refresh the purchase overview to load the current store-scoped operating baseline.';
    }
    if (recommendationRun.isRunning) {
      return 'Wait for the active recommendation runtime to finish before reviewing the latest snapshot state.';
    }
    if (recommendationSnapshot.run == null) {
      return 'Generate a recommendation snapshot so the purchase workflow can move beyond the overview baseline.';
    }
    if (recommendationSnapshot.lines.isEmpty) {
      return 'Review why the latest snapshot has no supplier-qualified lines before trying to create purchase orders.';
    }
    if (orderSummary.orders.isEmpty) {
      return 'Create purchase orders from the latest snapshot to open the operator runtime path.';
    }
    if (orderDetail.order == null) {
      return 'Select a recent purchase order to inspect approval handoff, receiving readiness, and blocked reasons together.';
    }
    if (runtimeClosure.approvalStateLabel == 'Ready to approve') {
      return 'Hand off the selected purchase order to the Office approval owner and keep POS on visibility-only duty.';
    }
    if (runtimeClosure.canConfirmReceipt) {
      return 'Physically verify the inbound goods, then use the tracked POS receipt confirmation contract for the remaining quantity.';
    }
    if (runtimeClosure.receivingStateLabel == 'Received / closed') {
      return 'Use receipt history and line context to verify the final received state without opening more runtime actions.';
    }
    if (blockedReasons.isNotEmpty) {
      return 'Review the blocked reasons first, then follow the handoff target before attempting any next workflow step.';
    }
    return 'Continue monitoring the selected purchase order from the unified runtime operating summary.';
  }();

  final operatingNarrative = orderDetail.order == null
      ? 'Inventory operators can read the full runtime flow here, but the selected purchase-order closure only appears after a tracked recent purchase order is loaded.'
      : 'Inventory operators can read recommendation status, purchase-order readiness, approval handoff, receiving readiness, blocked reasons, and the selected purchase-order runtime closure from one POS surface before taking the next allowed action.';

  return InventoryPurchaseOperatingSummary(
    recommendationRuntimeStateLabel: recommendationRuntimeStateLabel,
    latestSnapshotStateLabel: latestSnapshotStateLabel,
    purchaseOrderCreationReadinessLabel: purchaseOrderCreationReadinessLabel,
    approvalHandoffReadinessLabel: approvalHandoffReadinessLabel,
    receivingReadinessLabel: receivingReadinessLabel,
    selectedPurchaseOrderRuntimeLabel: selectedPurchaseOrderRuntimeLabel,
    nextOperatorAction: nextOperatorAction,
    operatingNarrative: operatingNarrative,
    handoffTarget: runtimeClosure.handoffTarget,
    blockedReasons: blockedReasons,
    visibleRecommendationLineCount: recommendationSnapshot.lines.length,
    visiblePurchaseOrderCount: orderSummary.orders.length,
    visibleBlockedReasonCount: blockedReasons.length,
    hasSelectedPurchaseOrder: orderDetail.order != null,
    canConfirmReceipt: runtimeClosure.canConfirmReceipt,
  );
}

class InventoryPurchaseApprovalRuntimeState {
  final bool isEvaluating;
  final InventoryPurchaseRuntimeResult? result;

  const InventoryPurchaseApprovalRuntimeState({
    this.isEvaluating = false,
    this.result,
  });

  InventoryPurchaseApprovalRuntimeState copyWith({
    bool? isEvaluating,
    InventoryPurchaseRuntimeResult? result,
    bool clearResult = false,
  }) => InventoryPurchaseApprovalRuntimeState(
    isEvaluating: isEvaluating ?? this.isEvaluating,
    result: clearResult ? null : (result ?? this.result),
  );
}

class InventoryPurchaseApprovalRuntimeNotifier
    extends StateNotifier<InventoryPurchaseApprovalRuntimeState> {
  InventoryPurchaseApprovalRuntimeNotifier()
    : super(const InventoryPurchaseApprovalRuntimeState());

  Future<void> evaluate(Map<String, dynamic>? order) async {
    state = state.copyWith(isEvaluating: true, clearResult: true);
    state = state.copyWith(
      isEvaluating: false,
      result: _buildInventoryPurchaseApprovalRuntimeResult(order),
    );
  }

  void clear() {
    state = const InventoryPurchaseApprovalRuntimeState();
  }

  InventoryPurchaseRuntimeResult _buildInventoryPurchaseApprovalRuntimeResult(
    Map<String, dynamic>? order,
  ) {
    if (order == null) {
      return const InventoryPurchaseRuntimeResult(
        kind: InventoryPurchaseRuntimeResultKind.blocked,
        title: 'Approval handoff unavailable',
        message:
            'Select a purchase order first. POS can only evaluate Office-owned approval readiness after a tracked order is loaded.',
      );
    }

    final status = order['status']?.toString() ?? 'submitted';
    switch (status) {
      case 'submitted':
      case 'office_returned':
        return const InventoryPurchaseRuntimeResult(
          kind: InventoryPurchaseRuntimeResultKind.blocked,
          title: 'Ready to approve',
          message:
              'This purchase order is ready for Office review, but approval execution stays Office-owned. POS records the handoff boundary and does not call Office approval mutation here.',
        );
      case 'office_approved':
      case 'ordered':
      case 'partially_received':
      case 'received':
        return const InventoryPurchaseRuntimeResult(
          kind: InventoryPurchaseRuntimeResultKind.success,
          title: 'Approved',
          message:
              'Backend truth already shows this purchase order beyond the Office approval gate, so POS keeps the state visible without re-running any approval action.',
        );
      case 'office_rejected':
        return const InventoryPurchaseRuntimeResult(
          kind: InventoryPurchaseRuntimeResultKind.blocked,
          title: 'Approval blocked',
          message:
              'Office review rejected this purchase order. POS cannot override the Office-owned decision from the inventory runtime surface.',
        );
      case 'cancelled':
        return const InventoryPurchaseRuntimeResult(
          kind: InventoryPurchaseRuntimeResultKind.blocked,
          title: 'Approval cancelled',
          message:
              'This purchase order is cancelled in backend truth. POS does not reopen or re-approve cancelled inventory purchase orders.',
        );
      default:
        return const InventoryPurchaseRuntimeResult(
          kind: InventoryPurchaseRuntimeResultKind.blocked,
          title: 'Approval handoff pending',
          message:
              'This purchase order has not reached an Office-approvable state yet. POS keeps the workflow boundary visible only.',
        );
    }
  }
}

final inventoryPurchaseApprovalRuntimeProvider =
    StateNotifierProvider<
      InventoryPurchaseApprovalRuntimeNotifier,
      InventoryPurchaseApprovalRuntimeState
    >((ref) => InventoryPurchaseApprovalRuntimeNotifier());

class InventoryPurchaseReceivingRuntimeState {
  final bool isSubmitting;
  final InventoryPurchaseRuntimeResult? result;

  const InventoryPurchaseReceivingRuntimeState({
    this.isSubmitting = false,
    this.result,
  });

  InventoryPurchaseReceivingRuntimeState copyWith({
    bool? isSubmitting,
    InventoryPurchaseRuntimeResult? result,
    bool clearResult = false,
  }) => InventoryPurchaseReceivingRuntimeState(
    isSubmitting: isSubmitting ?? this.isSubmitting,
    result: clearResult ? null : (result ?? this.result),
  );
}

class InventoryPurchaseReceivingRuntimeNotifier
    extends StateNotifier<InventoryPurchaseReceivingRuntimeState> {
  InventoryPurchaseReceivingRuntimeNotifier()
    : super(const InventoryPurchaseReceivingRuntimeState());

  Future<bool> confirmRemainingReceipt({
    required Map<String, dynamic>? order,
    String? memo,
  }) async {
    final blockedResult = _blockedReceivingResult(order);
    if (blockedResult != null) {
      state = state.copyWith(result: blockedResult, isSubmitting: false);
      return false;
    }

    state = state.copyWith(isSubmitting: true, clearResult: true);
    try {
      final updatedOrder = await inventoryService
          .confirmInventoryPurchaseReceipt(
            purchaseOrderId: order!['id'].toString(),
            memo: memo,
          );
      final updatedStatus = updatedOrder['status']?.toString() ?? 'received';
      final title = updatedStatus == 'received'
          ? 'Received and closed'
          : 'Receiving confirmed';
      final message = updatedStatus == 'received'
          ? 'Backend truth confirmed the remaining receipt quantity and closed this purchase order as received.'
          : 'Backend truth confirmed receipt progress for this purchase order. Remaining quantity is still open for later receiving.';

      state = state.copyWith(
        isSubmitting: false,
        result: InventoryPurchaseRuntimeResult(
          kind: InventoryPurchaseRuntimeResultKind.success,
          title: title,
          message: message,
        ),
      );
      return true;
    } catch (e) {
      state = state.copyWith(
        isSubmitting: false,
        result: InventoryPurchaseRuntimeResult(
          kind: InventoryPurchaseRuntimeResultKind.failure,
          title: 'Receiving failed',
          message: _mapInventoryPurchaseReceivingError(e),
        ),
      );
      return false;
    }
  }

  void markCancelled() {
    state = state.copyWith(
      result: const InventoryPurchaseRuntimeResult(
        kind: InventoryPurchaseRuntimeResultKind.cancelled,
        title: 'Receiving cancelled',
        message:
            'Receipt confirmation was cancelled before any backend mutation was sent.',
      ),
    );
  }

  void clear() {
    state = const InventoryPurchaseReceivingRuntimeState();
  }

  InventoryPurchaseRuntimeResult? _blockedReceivingResult(
    Map<String, dynamic>? order,
  ) {
    if (order == null) {
      return const InventoryPurchaseRuntimeResult(
        kind: InventoryPurchaseRuntimeResultKind.blocked,
        title: 'Receiving blocked',
        message:
            'Select a purchase order first. POS can only evaluate receiving readiness after a tracked order is loaded.',
      );
    }

    final status = order['status']?.toString() ?? 'submitted';
    final remainingBase =
        (order['total_remaining_quantity_base'] as num?)?.toDouble() ?? 0;

    if (status == 'received' || remainingBase <= 0) {
      return const InventoryPurchaseRuntimeResult(
        kind: InventoryPurchaseRuntimeResultKind.success,
        title: 'Received and closed',
        message:
            'Backend truth already shows this purchase order as fully received, so POS does not send another receipt confirmation.',
      );
    }

    if (status == 'office_rejected') {
      return const InventoryPurchaseRuntimeResult(
        kind: InventoryPurchaseRuntimeResultKind.blocked,
        title: 'Receiving blocked',
        message:
            'Office rejected this purchase order, so receipt confirmation cannot run from POS.',
      );
    }

    if (status == 'cancelled') {
      return const InventoryPurchaseRuntimeResult(
        kind: InventoryPurchaseRuntimeResultKind.blocked,
        title: 'Receiving blocked',
        message:
            'This purchase order is cancelled in backend truth, so receipt confirmation and stock mutation stay unavailable.',
      );
    }

    if (status == 'submitted' || status == 'office_returned') {
      return const InventoryPurchaseRuntimeResult(
        kind: InventoryPurchaseRuntimeResultKind.blocked,
        title: 'Receiving blocked',
        message:
            'Office approval is still missing. POS cannot confirm receipt or mutate stock before the backend order reaches an approved or ordered state.',
      );
    }

    if (status != 'office_approved' &&
        status != 'ordered' &&
        status != 'partially_received') {
      return InventoryPurchaseRuntimeResult(
        kind: InventoryPurchaseRuntimeResultKind.blocked,
        title: 'Receiving blocked',
        message:
            'This purchase order is currently in status $status, which the backend does not treat as receivable.',
      );
    }

    return null;
  }

  String _mapInventoryPurchaseReceivingError(Object error) {
    final fallback = 'Failed to confirm receiving from backend truth.';
    final message = error.toString();

    if (message.contains('INVENTORY_PURCHASE_NOT_FOUND')) {
      return 'The selected purchase order no longer exists in backend truth.';
    }
    if (message.contains('INVENTORY_PURCHASE_FORBIDDEN')) {
      return 'No permission to confirm receiving for this store.';
    }
    if (message.contains('INVENTORY_PURCHASE_NOT_RECEIVABLE')) {
      return 'The backend does not currently allow receiving for this purchase-order status.';
    }
    if (message.contains('INVENTORY_PURCHASE_LINE_NOT_FOUND')) {
      return 'One or more purchase-order lines are no longer available for receiving.';
    }

    return fallback;
  }
}

final inventoryPurchaseReceivingRuntimeProvider =
    StateNotifierProvider<
      InventoryPurchaseReceivingRuntimeNotifier,
      InventoryPurchaseReceivingRuntimeState
    >((ref) => InventoryPurchaseReceivingRuntimeNotifier());
