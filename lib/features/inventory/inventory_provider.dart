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

class InventoryPurchaseNewMenuState {
  final List<Map<String, dynamic>> categories;
  final bool isLoading;
  final bool isSaving;
  final String? error;
  final Map<String, dynamic>? lastCreatedMenu;

  const InventoryPurchaseNewMenuState({
    this.categories = const [],
    this.isLoading = false,
    this.isSaving = false,
    this.error,
    this.lastCreatedMenu,
  });

  InventoryPurchaseNewMenuState copyWith({
    List<Map<String, dynamic>>? categories,
    bool? isLoading,
    bool? isSaving,
    String? error,
    bool clearError = false,
    Map<String, dynamic>? lastCreatedMenu,
  }) => InventoryPurchaseNewMenuState(
    categories: categories ?? this.categories,
    isLoading: isLoading ?? this.isLoading,
    isSaving: isSaving ?? this.isSaving,
    error: clearError ? null : (error ?? this.error),
    lastCreatedMenu: lastCreatedMenu ?? this.lastCreatedMenu,
  );
}

class InventoryPurchaseNewMenuNotifier
    extends StateNotifier<InventoryPurchaseNewMenuState> {
  InventoryPurchaseNewMenuNotifier()
    : super(const InventoryPurchaseNewMenuState());

  Future<void> loadCategories(String storeId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final categories = await inventoryService.fetchMenuCategories(storeId);
      state = state.copyWith(categories: categories, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapNewMenuError(e, 'Failed to load menu categories.'),
      );
    }
  }

  Future<bool> create({
    required String storeId,
    String? categoryId,
    required String name,
    required double price,
    String? description,
    required List<Map<String, dynamic>> recipeLines,
  }) async {
    state = state.copyWith(isSaving: true, clearError: true);
    try {
      final menu = await inventoryService.createInventoryMenuWithRecipe(
        storeId: storeId,
        categoryId: categoryId,
        name: name,
        price: price,
        description: description,
        recipeLines: recipeLines,
      );
      state = state.copyWith(isSaving: false, lastCreatedMenu: menu);
      return true;
    } catch (e) {
      state = state.copyWith(
        isSaving: false,
        error: _mapNewMenuError(e, 'Failed to create menu with recipe.'),
      );
      return false;
    }
  }

  String _mapNewMenuError(Object error, String fallback) {
    final message = error is PostgrestException
        ? error.message
        : error.toString();

    if (message.contains('INVENTORY_MENU_CREATE_FORBIDDEN')) {
      return 'No permission to create menu recipes for this store.';
    }
    if (message.contains('MENU_ITEM_NAME_REQUIRED')) {
      return 'Enter a menu name.';
    }
    if (message.contains('MENU_ITEM_PRICE_INVALID')) {
      return 'Menu price must be zero or greater.';
    }
    if (message.contains('MENU_RECIPE_LINES_REQUIRED')) {
      return 'Add at least one recipe ingredient.';
    }
    if (message.contains('MENU_CATEGORY_NOT_FOUND')) {
      return 'Selected category is no longer available.';
    }
    if (message.contains('MENU_RECIPE_LINE_INVALID')) {
      return 'Recipe ingredient and usage must be valid.';
    }
    if (message.contains('MENU_RECIPE_PRODUCT_NOT_FOUND')) {
      return 'Recipe ingredients must be active gram-based inventory products.';
    }

    return fallback;
  }
}

final inventoryPurchaseNewMenuProvider =
    StateNotifierProvider<
      InventoryPurchaseNewMenuNotifier,
      InventoryPurchaseNewMenuState
    >((ref) => InventoryPurchaseNewMenuNotifier());

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

class InventoryPurchaseSupplierCatalogState {
  final List<Map<String, dynamic>> suppliers;
  final List<Map<String, dynamic>> supplierItems;
  final bool isLoading;
  final bool isSaving;
  final String? error;

  const InventoryPurchaseSupplierCatalogState({
    this.suppliers = const [],
    this.supplierItems = const [],
    this.isLoading = false,
    this.isSaving = false,
    this.error,
  });

  InventoryPurchaseSupplierCatalogState copyWith({
    List<Map<String, dynamic>>? suppliers,
    List<Map<String, dynamic>>? supplierItems,
    bool? isLoading,
    bool? isSaving,
    String? error,
    bool clearError = false,
  }) => InventoryPurchaseSupplierCatalogState(
    suppliers: suppliers ?? this.suppliers,
    supplierItems: supplierItems ?? this.supplierItems,
    isLoading: isLoading ?? this.isLoading,
    isSaving: isSaving ?? this.isSaving,
    error: clearError ? null : (error ?? this.error),
  );
}

class InventoryPurchaseSupplierCatalogNotifier
    extends StateNotifier<InventoryPurchaseSupplierCatalogState> {
  InventoryPurchaseSupplierCatalogNotifier()
    : super(const InventoryPurchaseSupplierCatalogState());

  Future<void> load(String storeId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final suppliers = await inventoryService.fetchInventorySuppliers(
        storeId: storeId,
      );
      final supplierItems = await inventoryService.fetchInventorySupplierItems(
        storeId: storeId,
      );
      state = state.copyWith(
        suppliers: suppliers,
        supplierItems: supplierItems,
        isLoading: false,
      );
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapSupplierCatalogError(e, 'Failed to load suppliers.'),
      );
    }
  }

  Future<bool> saveSupplier({
    required String storeId,
    String? supplierId,
    required String supplierName,
    String? supplierType,
    String? contactName,
    String? phone,
    String? email,
    String? address,
    String? businessRegistrationNo,
    String? bankAccountNumber,
    String? paymentTerms,
    DateTime? contractStartDate,
    DateTime? contractEndDate,
    String? memo,
  }) async {
    state = state.copyWith(isSaving: true, clearError: true);
    try {
      await inventoryService.upsertInventorySupplier(
        storeId: storeId,
        supplierId: supplierId,
        supplierName: supplierName,
        supplierType: supplierType,
        contactName: contactName,
        phone: phone,
        email: email,
        address: address,
        businessRegistrationNo: businessRegistrationNo,
        bankAccountNumber: bankAccountNumber,
        paymentTerms: paymentTerms,
        contractStartDate: contractStartDate,
        contractEndDate: contractEndDate,
        memo: memo,
      );
      await load(storeId);
      state = state.copyWith(isSaving: false);
      return true;
    } catch (e) {
      state = state.copyWith(
        isSaving: false,
        error: _mapSupplierCatalogError(e, 'Failed to save supplier.'),
      );
      return false;
    }
  }

  Future<bool> setSupplierStatus({
    required String storeId,
    required String supplierId,
    required String status,
  }) async {
    state = state.copyWith(isSaving: true, clearError: true);
    try {
      await inventoryService.setInventorySupplierStatus(
        storeId: storeId,
        supplierId: supplierId,
        status: status,
      );
      await load(storeId);
      state = state.copyWith(isSaving: false);
      return true;
    } catch (e) {
      state = state.copyWith(
        isSaving: false,
        error: _mapSupplierCatalogError(e, 'Failed to update supplier status.'),
      );
      return false;
    }
  }

  Future<bool> saveSupplierItem({
    required String storeId,
    String? supplierItemId,
    required String supplierId,
    required String productId,
    String? supplierSku,
    required String orderUnit,
    required double orderUnitQuantityBase,
    required double minOrderQuantity,
    required double unitPrice,
    required double taxRate,
    required int leadTimeDays,
    required bool isPreferred,
  }) async {
    state = state.copyWith(isSaving: true, clearError: true);
    try {
      await inventoryService.upsertInventorySupplierItem(
        storeId: storeId,
        supplierItemId: supplierItemId,
        supplierId: supplierId,
        productId: productId,
        supplierSku: supplierSku,
        orderUnit: orderUnit,
        orderUnitQuantityBase: orderUnitQuantityBase,
        minOrderQuantity: minOrderQuantity,
        unitPrice: unitPrice,
        taxRate: taxRate,
        leadTimeDays: leadTimeDays,
        isPreferred: isPreferred,
      );
      await load(storeId);
      state = state.copyWith(isSaving: false);
      return true;
    } catch (e) {
      state = state.copyWith(
        isSaving: false,
        error: _mapSupplierCatalogError(e, 'Failed to save supplier item.'),
      );
      return false;
    }
  }

  Future<bool> setSupplierItemActive({
    required String storeId,
    required String supplierItemId,
    required bool isActive,
  }) async {
    state = state.copyWith(isSaving: true, clearError: true);
    try {
      await inventoryService.setInventorySupplierItemActive(
        storeId: storeId,
        supplierItemId: supplierItemId,
        isActive: isActive,
      );
      await load(storeId);
      state = state.copyWith(isSaving: false);
      return true;
    } catch (e) {
      state = state.copyWith(
        isSaving: false,
        error: _mapSupplierCatalogError(
          e,
          'Failed to update supplier item status.',
        ),
      );
      return false;
    }
  }

  String _mapSupplierCatalogError(Object error, String fallback) {
    final message = error is PostgrestException
        ? error.message
        : error.toString();

    if (message.contains('INVENTORY_SUPPLIER_FORBIDDEN') ||
        message.contains('INVENTORY_SUPPLIER_ITEM_FORBIDDEN')) {
      return 'No permission to manage suppliers for this store.';
    }
    if (message.contains('SUPPLIER_NAME_REQUIRED')) {
      return 'Enter a supplier name.';
    }
    if (message.contains('SUPPLIER_STATUS_INVALID')) {
      return 'Supplier status must be active, inactive, or suspended.';
    }
    if (message.contains('SUPPLIER_NOT_FOUND')) {
      return 'Supplier is no longer available.';
    }
    if (message.contains('PRODUCT_NOT_FOUND')) {
      return 'Select an active product for this supplier item.';
    }
    if (message.contains('ORDER_UNIT_REQUIRED')) {
      return 'Enter an order unit.';
    }
    if (message.contains('ORDER_UNIT_QUANTITY_INVALID')) {
      return 'Order unit quantity must be greater than zero.';
    }
    if (message.contains('MIN_ORDER_QUANTITY_INVALID')) {
      return 'Minimum order quantity must be greater than zero.';
    }
    if (message.contains('UNIT_PRICE_INVALID')) {
      return 'Unit price must be zero or greater.';
    }
    if (message.contains('TAX_RATE_INVALID')) {
      return 'Tax rate must be zero or greater.';
    }
    if (message.contains('LEAD_TIME_INVALID')) {
      return 'Lead time must be zero or greater.';
    }
    if (message.contains('SUPPLIER_ITEM_NOT_FOUND')) {
      return 'Supplier item is no longer available.';
    }

    return fallback;
  }
}

final inventoryPurchaseSupplierCatalogProvider =
    StateNotifierProvider<
      InventoryPurchaseSupplierCatalogNotifier,
      InventoryPurchaseSupplierCatalogState
    >((ref) => InventoryPurchaseSupplierCatalogNotifier());

class InventoryPurchaseProductCatalogState {
  final List<Map<String, dynamic>> products;
  final bool isLoading;
  final bool isSaving;
  final String? error;

  const InventoryPurchaseProductCatalogState({
    this.products = const [],
    this.isLoading = false,
    this.isSaving = false,
    this.error,
  });

  InventoryPurchaseProductCatalogState copyWith({
    List<Map<String, dynamic>>? products,
    bool? isLoading,
    bool? isSaving,
    String? error,
    bool clearError = false,
  }) => InventoryPurchaseProductCatalogState(
    products: products ?? this.products,
    isLoading: isLoading ?? this.isLoading,
    isSaving: isSaving ?? this.isSaving,
    error: clearError ? null : (error ?? this.error),
  );
}

class InventoryPurchaseProductCatalogNotifier
    extends StateNotifier<InventoryPurchaseProductCatalogState> {
  InventoryPurchaseProductCatalogNotifier()
    : super(const InventoryPurchaseProductCatalogState());

  Future<void> load(String storeId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final products = await inventoryService.fetchInventoryProducts(
        storeId: storeId,
      );
      state = state.copyWith(products: products, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapProductCatalogError(e, 'Failed to load products.'),
      );
    }
  }

  Future<bool> saveProduct({
    required String storeId,
    String? productId,
    String? productCode,
    required String name,
    String? category,
    required String stockUnit,
    required String baseUnit,
    required double baseUnitFactor,
    String? imageUrl,
    String? storageType,
    int? shelfLifeDays,
    bool isOrderable = true,
  }) async {
    state = state.copyWith(isSaving: true, clearError: true);
    try {
      await inventoryService.upsertInventoryProduct(
        storeId: storeId,
        productId: productId,
        productCode: productCode,
        name: name,
        category: category,
        stockUnit: stockUnit,
        baseUnit: baseUnit,
        baseUnitFactor: baseUnitFactor,
        imageUrl: imageUrl,
        storageType: storageType,
        shelfLifeDays: shelfLifeDays,
        isOrderable: isOrderable,
      );
      await load(storeId);
      state = state.copyWith(isSaving: false);
      return true;
    } catch (e) {
      state = state.copyWith(
        isSaving: false,
        error: _mapProductCatalogError(e, 'Failed to save product.'),
      );
      return false;
    }
  }

  Future<bool> setProductActive({
    required String storeId,
    required String productId,
    required bool isActive,
  }) async {
    state = state.copyWith(isSaving: true, clearError: true);
    try {
      await inventoryService.setInventoryProductActive(
        storeId: storeId,
        productId: productId,
        isActive: isActive,
      );
      await load(storeId);
      state = state.copyWith(isSaving: false);
      return true;
    } catch (e) {
      state = state.copyWith(
        isSaving: false,
        error: _mapProductCatalogError(e, 'Failed to update product status.'),
      );
      return false;
    }
  }

  String _mapProductCatalogError(Object error, String fallback) {
    final message = error is PostgrestException
        ? error.message
        : error.toString();

    if (message.contains('INVENTORY_PRODUCT_FORBIDDEN')) {
      return 'No permission to manage products for this store.';
    }
    if (message.contains('PRODUCT_NAME_REQUIRED')) {
      return 'Enter a product name.';
    }
    if (message.contains('STOCK_UNIT_REQUIRED')) {
      return 'Enter a stock unit.';
    }
    if (message.contains('BASE_UNIT_INVALID')) {
      return 'Base unit must be g, ml, or ea.';
    }
    if (message.contains('BASE_UNIT_FACTOR_INVALID')) {
      return 'Base unit factor must be greater than zero.';
    }
    if (message.contains('SHELF_LIFE_INVALID')) {
      return 'Shelf life must be zero or greater.';
    }
    if (message.contains('PRODUCT_NOT_FOUND')) {
      return 'Product is no longer available.';
    }

    return fallback;
  }
}

final inventoryPurchaseProductCatalogProvider =
    StateNotifierProvider<
      InventoryPurchaseProductCatalogNotifier,
      InventoryPurchaseProductCatalogState
    >((ref) => InventoryPurchaseProductCatalogNotifier());

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

class InventoryPurchaseStockStatusState {
  final List<Map<String, dynamic>> rows;
  final bool isLoading;
  final String? error;

  const InventoryPurchaseStockStatusState({
    this.rows = const [],
    this.isLoading = false,
    this.error,
  });

  InventoryPurchaseStockStatusState copyWith({
    List<Map<String, dynamic>>? rows,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) => InventoryPurchaseStockStatusState(
    rows: rows ?? this.rows,
    isLoading: isLoading ?? this.isLoading,
    error: clearError ? null : (error ?? this.error),
  );
}

class InventoryPurchaseStockStatusNotifier
    extends StateNotifier<InventoryPurchaseStockStatusState> {
  InventoryPurchaseStockStatusNotifier()
    : super(const InventoryPurchaseStockStatusState());

  Future<void> load(String storeId, {DateTime? asOfDate}) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final rows = await inventoryService.fetchInventoryStockStatus(
        storeId: storeId,
        asOfDate: asOfDate,
      );
      state = state.copyWith(rows: rows, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapInventoryPurchaseStockStatusError(e),
      );
    }
  }

  String _mapInventoryPurchaseStockStatusError(Object error) {
    final fallback = 'Failed to load inventory stock status.';
    final message = error.toString();

    if (message.contains('INVENTORY_PURCHASE_FORBIDDEN')) {
      return 'No permission to view inventory stock status for this store.';
    }

    return fallback;
  }
}

final inventoryPurchaseStockStatusProvider =
    StateNotifierProvider<
      InventoryPurchaseStockStatusNotifier,
      InventoryPurchaseStockStatusState
    >((ref) => InventoryPurchaseStockStatusNotifier());

class InventoryPurchaseCostAnalysisState {
  final List<Map<String, dynamic>> rows;
  final bool isLoading;
  final bool isRefreshing;
  final int? lastRefreshCount;
  final String? error;

  const InventoryPurchaseCostAnalysisState({
    this.rows = const [],
    this.isLoading = false,
    this.isRefreshing = false,
    this.lastRefreshCount,
    this.error,
  });

  InventoryPurchaseCostAnalysisState copyWith({
    List<Map<String, dynamic>>? rows,
    bool? isLoading,
    bool? isRefreshing,
    int? lastRefreshCount,
    String? error,
    bool clearError = false,
  }) => InventoryPurchaseCostAnalysisState(
    rows: rows ?? this.rows,
    isLoading: isLoading ?? this.isLoading,
    isRefreshing: isRefreshing ?? this.isRefreshing,
    lastRefreshCount: lastRefreshCount ?? this.lastRefreshCount,
    error: clearError ? null : (error ?? this.error),
  );
}

class InventoryPurchaseCostAnalysisNotifier
    extends StateNotifier<InventoryPurchaseCostAnalysisState> {
  InventoryPurchaseCostAnalysisNotifier()
    : super(const InventoryPurchaseCostAnalysisState());

  Future<void> load(String storeId, {DateTime? from, DateTime? to}) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final rows = await inventoryService.fetchInventoryCostAnalysis(
        storeId: storeId,
        from: from,
        to: to,
      );
      state = state.copyWith(rows: rows, isLoading: false);
    } catch (e) {
      state = state.copyWith(
        isLoading: false,
        error: _mapCostAnalysisError(e, 'Failed to load cost analysis.'),
      );
    }
  }

  Future<bool> refreshConsumption(
    String storeId, {
    DateTime? from,
    DateTime? to,
  }) async {
    state = state.copyWith(isRefreshing: true, clearError: true);
    try {
      final count = await inventoryService.refreshInventoryDailyConsumption(
        storeId: storeId,
        from: from,
        to: to,
      );
      final rows = await inventoryService.fetchInventoryCostAnalysis(
        storeId: storeId,
        from: from,
        to: to,
      );
      state = state.copyWith(
        rows: rows,
        isRefreshing: false,
        lastRefreshCount: count,
      );
      return true;
    } catch (e) {
      state = state.copyWith(
        isRefreshing: false,
        error: _mapCostAnalysisError(e, 'Failed to refresh consumption.'),
      );
      return false;
    }
  }

  String _mapCostAnalysisError(Object error, String fallback) {
    final message = error.toString();

    if (message.contains('INVENTORY_COST_ANALYSIS_FORBIDDEN') ||
        message.contains('INVENTORY_CONSUMPTION_REFRESH_FORBIDDEN')) {
      return 'No permission to analyze inventory cost for this store.';
    }
    if (message.contains('INVENTORY_COST_ANALYSIS_DATE_RANGE_INVALID') ||
        message.contains('INVENTORY_CONSUMPTION_DATE_RANGE_INVALID')) {
      return 'Check the analysis date range.';
    }

    return fallback;
  }
}

final inventoryPurchaseCostAnalysisProvider =
    StateNotifierProvider<
      InventoryPurchaseCostAnalysisNotifier,
      InventoryPurchaseCostAnalysisState
    >((ref) => InventoryPurchaseCostAnalysisNotifier());

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

class InventoryPurchaseRecommendationAdjustmentState {
  final String? updatingLineId;
  final String? error;
  final Map<String, dynamic>? lastUpdatedLine;

  const InventoryPurchaseRecommendationAdjustmentState({
    this.updatingLineId,
    this.error,
    this.lastUpdatedLine,
  });

  bool get isUpdating => updatingLineId != null;

  InventoryPurchaseRecommendationAdjustmentState copyWith({
    String? updatingLineId,
    String? error,
    bool clearUpdatingLine = false,
    bool clearError = false,
    Map<String, dynamic>? lastUpdatedLine,
  }) => InventoryPurchaseRecommendationAdjustmentState(
    updatingLineId: clearUpdatingLine
        ? null
        : (updatingLineId ?? this.updatingLineId),
    error: clearError ? null : (error ?? this.error),
    lastUpdatedLine: lastUpdatedLine ?? this.lastUpdatedLine,
  );
}

class InventoryPurchaseRecommendationAdjustmentNotifier
    extends StateNotifier<InventoryPurchaseRecommendationAdjustmentState> {
  InventoryPurchaseRecommendationAdjustmentNotifier()
    : super(const InventoryPurchaseRecommendationAdjustmentState());

  Future<bool> update({
    required String lineId,
    double? adjustedOrderUnits,
    String? memo,
  }) async {
    state = state.copyWith(updatingLineId: lineId, clearError: true);
    try {
      final line = await inventoryService
          .updateInventoryRecommendationLineAdjustment(
            lineId: lineId,
            adjustedOrderUnits: adjustedOrderUnits,
            memo: memo,
          );
      state = state.copyWith(clearUpdatingLine: true, lastUpdatedLine: line);
      return true;
    } catch (e) {
      state = state.copyWith(
        clearUpdatingLine: true,
        error: _mapInventoryPurchaseRecommendationAdjustmentError(e),
      );
      return false;
    }
  }

  String _mapInventoryPurchaseRecommendationAdjustmentError(Object error) {
    final fallback = 'Failed to update recommendation adjustment.';
    final message = error.toString();

    if (message.contains('INVENTORY_PURCHASE_FORBIDDEN')) {
      return 'No permission to adjust this recommendation line.';
    }
    if (message.contains('INVENTORY_RECOMMENDATION_LINE_NOT_FOUND')) {
      return 'The selected recommendation line is no longer available.';
    }
    if (message.contains('INVENTORY_RECOMMENDATION_ADJUSTMENT_INVALID')) {
      return 'Adjusted order units must be zero or greater.';
    }
    if (message.contains('INVENTORY_SUPPLIER_ITEM_NOT_FOUND')) {
      return 'The selected recommendation line has no active supplier item.';
    }

    return fallback;
  }
}

final inventoryPurchaseRecommendationAdjustmentProvider =
    StateNotifierProvider<
      InventoryPurchaseRecommendationAdjustmentNotifier,
      InventoryPurchaseRecommendationAdjustmentState
    >((ref) => InventoryPurchaseRecommendationAdjustmentNotifier());

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

  Future<bool> createManual({
    required String storeId,
    required String supplierId,
    required List<Map<String, dynamic>> lines,
    DateTime? requestedDeliveryDate,
    String? memo,
  }) async {
    state = state.copyWith(isCreating: true, clearError: true);
    try {
      final order = await inventoryService.createManualInventoryPurchaseOrder(
        storeId: storeId,
        supplierId: supplierId,
        lines: lines,
        requestedDeliveryDate: requestedDeliveryDate,
        memo: memo,
      );
      state = state.copyWith(isCreating: false, createdOrders: [order]);
      return true;
    } catch (e) {
      state = state.copyWith(
        isCreating: false,
        error: _mapInventoryPurchaseOrderCreationError(e),
      );
      return false;
    }
  }

  Future<bool> createRepeat({
    required String sourcePurchaseOrderId,
    DateTime? requestedDeliveryDate,
    String? memo,
  }) async {
    state = state.copyWith(isCreating: true, clearError: true);
    try {
      final order = await inventoryService.createRepeatInventoryPurchaseOrder(
        sourcePurchaseOrderId: sourcePurchaseOrderId,
        requestedDeliveryDate: requestedDeliveryDate,
        memo: memo,
      );
      state = state.copyWith(isCreating: false, createdOrders: [order]);
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
    if (message.contains('INVENTORY_MANUAL_PURCHASE_FORBIDDEN')) {
      return 'No permission to create manual purchase orders for this store.';
    }
    if (message.contains('INVENTORY_MANUAL_PURCHASE_SUPPLIER_REQUIRED')) {
      return 'Select a supplier for this manual purchase order.';
    }
    if (message.contains('INVENTORY_MANUAL_PURCHASE_LINES_REQUIRED')) {
      return 'Add at least one supplier item to create a manual purchase order.';
    }
    if (message.contains('INVENTORY_MANUAL_PURCHASE_QUANTITY_INVALID')) {
      return 'Manual purchase quantity must be greater than zero.';
    }
    if (message.contains('INVENTORY_MANUAL_PURCHASE_SUPPLIER_ITEM_NOT_FOUND')) {
      return 'Manual purchase line must use an active item for the selected supplier.';
    }
    if (message.contains('INVENTORY_REPEAT_PURCHASE_SOURCE_NOT_FOUND')) {
      return 'The source purchase order for repeat ordering was not found.';
    }
    if (message.contains('INVENTORY_REPEAT_PURCHASE_FORBIDDEN')) {
      return 'No permission to create repeat purchase orders for this store.';
    }
    if (message.contains('INVENTORY_REPEAT_PURCHASE_SUPPLIER_REQUIRED')) {
      return 'The source purchase order has no supplier.';
    }
    if (message.contains('INVENTORY_REPEAT_PURCHASE_LINES_REQUIRED')) {
      return 'The source purchase order has no lines to repeat.';
    }
    if (message.contains('INVENTORY_REPEAT_PURCHASE_QUANTITY_INVALID')) {
      return 'Repeat purchase quantity must be greater than zero.';
    }
    if (message.contains('INVENTORY_REPEAT_PURCHASE_SUPPLIER_ITEM_NOT_FOUND')) {
      return 'Repeat purchase lines must use active supplier items.';
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

class InventoryPurchaseStockAuditState {
  final bool isSaving;
  final String? error;
  final String? lastSessionId;
  final bool lastCompleted;

  const InventoryPurchaseStockAuditState({
    this.isSaving = false,
    this.error,
    this.lastSessionId,
    this.lastCompleted = false,
  });

  InventoryPurchaseStockAuditState copyWith({
    bool? isSaving,
    String? error,
    bool clearError = false,
    String? lastSessionId,
    bool? lastCompleted,
  }) => InventoryPurchaseStockAuditState(
    isSaving: isSaving ?? this.isSaving,
    error: clearError ? null : (error ?? this.error),
    lastSessionId: lastSessionId ?? this.lastSessionId,
    lastCompleted: lastCompleted ?? this.lastCompleted,
  );
}

class InventoryPurchaseStockAuditNotifier
    extends StateNotifier<InventoryPurchaseStockAuditState> {
  InventoryPurchaseStockAuditNotifier()
    : super(const InventoryPurchaseStockAuditState());

  Future<bool> save({
    required String storeId,
    required List<Map<String, dynamic>> lines,
    String? memo,
    required bool complete,
    String? sessionId,
  }) async {
    state = state.copyWith(isSaving: true, clearError: true);
    try {
      final savedSessionId = await inventoryService.saveInventoryStockAudit(
        storeId: storeId,
        lines: lines,
        memo: memo,
        complete: complete,
        sessionId: sessionId ?? state.lastSessionId,
      );
      state = state.copyWith(
        isSaving: false,
        lastSessionId: savedSessionId,
        lastCompleted: complete,
      );
      return true;
    } catch (e) {
      state = state.copyWith(isSaving: false, error: _mapStockAuditError(e));
      return false;
    }
  }

  String _mapStockAuditError(Object error) {
    final fallback = 'Failed to save stock audit.';
    final message = error.toString();

    if (message.contains('INVENTORY_STOCK_AUDIT_FORBIDDEN')) {
      return 'No permission to save stock audit for this store.';
    }
    if (message.contains('INVENTORY_STOCK_AUDIT_LINES_REQUIRED')) {
      return 'Enter at least one counted product quantity.';
    }
    if (message.contains('INVENTORY_STOCK_AUDIT_SESSION_NOT_FOUND')) {
      return 'The stock audit session no longer exists.';
    }
    if (message.contains('INVENTORY_STOCK_AUDIT_SESSION_NOT_EDITABLE')) {
      return 'The selected stock audit session is already closed.';
    }
    if (message.contains('INVENTORY_STOCK_AUDIT_PRODUCT_REQUIRED')) {
      return 'A counted product is missing.';
    }
    if (message.contains('INVENTORY_STOCK_AUDIT_ACTUAL_INVALID')) {
      return 'Actual stock quantity must be zero or greater.';
    }
    if (message.contains('INVENTORY_STOCK_AUDIT_PRODUCT_NOT_FOUND') ||
        message.contains('INVENTORY_STOCK_AUDIT_ITEM_NOT_LINKED') ||
        message.contains('INVENTORY_STOCK_AUDIT_ITEM_NOT_FOUND')) {
      return 'One or more counted products are no longer linked to inventory stock.';
    }

    return fallback;
  }
}

final inventoryPurchaseStockAuditProvider =
    StateNotifierProvider<
      InventoryPurchaseStockAuditNotifier,
      InventoryPurchaseStockAuditState
    >((ref) => InventoryPurchaseStockAuditNotifier());

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

class InventoryPurchaseActionQueueEntry {
  final String orderId;
  final String purchaseOrderNo;
  final String supplierLabel;
  final String priorityBucket;
  final String blockerSeverity;
  final String handoffTarget;
  final String staleLabel;
  final String nextAction;
  final String operatorReason;
  final bool isSelected;

  const InventoryPurchaseActionQueueEntry({
    required this.orderId,
    required this.purchaseOrderNo,
    required this.supplierLabel,
    required this.priorityBucket,
    required this.blockerSeverity,
    required this.handoffTarget,
    required this.staleLabel,
    required this.nextAction,
    required this.operatorReason,
    required this.isSelected,
  });
}

class InventoryPurchaseReconciliationSummary {
  final int recommendedCount;
  final int orderedCount;
  final int receivedCount;
  final int remainingCount;
  final int delayedCount;
  final String mismatchIndicatorLabel;
  final String mismatchIndicatorTone;
  final String narrative;

  const InventoryPurchaseReconciliationSummary({
    required this.recommendedCount,
    required this.orderedCount,
    required this.receivedCount,
    required this.remainingCount,
    required this.delayedCount,
    required this.mismatchIndicatorLabel,
    required this.mismatchIndicatorTone,
    required this.narrative,
  });
}

class InventoryPurchaseSupplierBottleneckState {
  final String supplierLabel;
  final int affectedPoCount;
  final String oldestWaitingAge;
  final String blockedReasonCluster;
  final String nextFollowUpTarget;
  final String severity;
  final String narrative;

  const InventoryPurchaseSupplierBottleneckState({
    required this.supplierLabel,
    required this.affectedPoCount,
    required this.oldestWaitingAge,
    required this.blockedReasonCluster,
    required this.nextFollowUpTarget,
    required this.severity,
    required this.narrative,
  });
}

class InventoryPurchaseReceivingSafetyState {
  final String lastAttemptLabel;
  final String retryDisciplineLabel;
  final String unknownOutcomeLabel;
  final String followUpGuidanceLabel;
  final String tone;
  final String narrative;

  const InventoryPurchaseReceivingSafetyState({
    required this.lastAttemptLabel,
    required this.retryDisciplineLabel,
    required this.unknownOutcomeLabel,
    required this.followUpGuidanceLabel,
    required this.tone,
    required this.narrative,
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
  final InventoryPurchaseReconciliationSummary reconciliationSummary;
  final List<InventoryPurchaseActionQueueEntry> actionQueue;
  final List<InventoryPurchaseSupplierBottleneckState> supplierBottlenecks;

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
    required this.reconciliationSummary,
    required this.actionQueue,
    required this.supplierBottlenecks,
  });
}

class InventoryPurchaseRuntimeSurfaceState {
  final Map<String, dynamic>? order;
  final String orderStatus;
  final String? requestedDate;
  final double remainingBase;
  final double expectedBase;
  final double receivedBase;
  final double acceptedBase;
  final double rejectedBase;
  final int confirmedReceiptCount;
  final int draftReceiptCount;
  final int cancelledReceiptCount;
  final int receivedLineCount;
  final int blockedLineCount;
  final int pendingLineCount;
  final int attentionLineCount;
  final String? latestReceiptStatus;
  final DateTime? latestReceiptAt;
  final String operationalPhaseLabel;
  final String operationalPhaseTone;
  final String operationalPhaseNarrative;
  final String approvalStateTone;
  final String approvalNarrative;
  final String receivingStateTone;
  final String receivingNarrative;
  final String receivingReadinessLabel;
  final String receivingReadinessTone;
  final String receivingReadinessNarrative;
  final String receiptVisibilityStatusLabel;
  final String receiptVisibilityStatusTone;
  final String receiptVisibilityNarrative;
  final String readyStateLabel;
  final String readyStateTone;
  final String blockedStateLabel;
  final String blockedStateTone;
  final String staleStateLabel;
  final String staleStateTone;
  final String nextBestOperatorAction;
  final String receivedLineSummaryLabel;
  final String remainingLineSummaryLabel;
  final List<Map<String, dynamic>> blockerRows;
  final List<InventoryPurchaseRuntimeLineContextState> lineContexts;
  final InventoryPurchaseReceivingSafetyState receivingSafety;
  final InventoryPurchaseRuntimeClosureSnapshot runtimeClosure;

  const InventoryPurchaseRuntimeSurfaceState({
    required this.order,
    required this.orderStatus,
    required this.requestedDate,
    required this.remainingBase,
    required this.expectedBase,
    required this.receivedBase,
    required this.acceptedBase,
    required this.rejectedBase,
    required this.confirmedReceiptCount,
    required this.draftReceiptCount,
    required this.cancelledReceiptCount,
    required this.receivedLineCount,
    required this.blockedLineCount,
    required this.pendingLineCount,
    required this.attentionLineCount,
    required this.latestReceiptStatus,
    required this.latestReceiptAt,
    required this.operationalPhaseLabel,
    required this.operationalPhaseTone,
    required this.operationalPhaseNarrative,
    required this.approvalStateTone,
    required this.approvalNarrative,
    required this.receivingStateTone,
    required this.receivingNarrative,
    required this.receivingReadinessLabel,
    required this.receivingReadinessTone,
    required this.receivingReadinessNarrative,
    required this.receiptVisibilityStatusLabel,
    required this.receiptVisibilityStatusTone,
    required this.receiptVisibilityNarrative,
    required this.readyStateLabel,
    required this.readyStateTone,
    required this.blockedStateLabel,
    required this.blockedStateTone,
    required this.staleStateLabel,
    required this.staleStateTone,
    required this.nextBestOperatorAction,
    required this.receivedLineSummaryLabel,
    required this.remainingLineSummaryLabel,
    required this.blockerRows,
    required this.lineContexts,
    required this.receivingSafety,
    required this.runtimeClosure,
  });
}

class InventoryPurchaseRuntimeLineContextState {
  final String productName;
  final double orderedBase;
  final double expectedBase;
  final double receivedBase;
  final double remainingBase;
  final String statusLabel;
  final String statusTone;
  final String riskSummary;
  final String narrative;

  const InventoryPurchaseRuntimeLineContextState({
    required this.productName,
    required this.orderedBase,
    required this.expectedBase,
    required this.receivedBase,
    required this.remainingBase,
    required this.statusLabel,
    required this.statusTone,
    required this.riskSummary,
    required this.narrative,
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
  required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
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
      : runtimeSurface.runtimeClosure.approvalStateLabel;
  final receivingReadinessLabel = orderDetail.order == null
      ? 'Receiving waiting selected PO'
      : runtimeSurface.receivingReadinessLabel;
  final selectedPurchaseOrderRuntimeLabel = orderDetail.order == null
      ? 'Selected PO runtime pending'
      : runtimeSurface.runtimeClosure.lastRuntimeStateLabel;
  final actionQueue = buildInventoryPurchaseActionQueue(
    orders: orderSummary.orders,
    selectedOrderId: orderDetail.selectedOrderId,
    runtimeSurface: runtimeSurface,
  );
  final reconciliationSummary = buildInventoryPurchaseReconciliationSummary(
    recommendedCount: recommendationSnapshot.lines.length,
    orders: orderSummary.orders,
  );
  final supplierBottlenecks = buildInventoryPurchaseSupplierBottlenecks(
    orders: orderSummary.orders,
  );

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
    ...runtimeSurface.runtimeClosure.blockedReasons,
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
      if (actionQueue.isNotEmpty) {
        final topQueue = actionQueue.first;
        return 'Select ${topQueue.purchaseOrderNo} from the operator action queue and ${topQueue.nextAction.toLowerCase()}';
      }
      return 'Select a recent purchase order to inspect approval handoff, receiving readiness, and blocked reasons together.';
    }
    return runtimeSurface.nextBestOperatorAction;
  }();

  final operatingNarrative = orderDetail.order == null
      ? 'Inventory operators can read the full runtime flow here, but the selected purchase-order closure only appears after a tracked recent purchase order is loaded. The provider-owned action queue, reconciliation summary, and supplier bottleneck view still show what the store should work on first.'
      : 'Inventory operators can read recommendation status, purchase-order readiness, approval handoff, receiving readiness, blocked reasons, the store-level action queue, supplier bottlenecks, and the selected purchase-order runtime closure from one POS surface before taking the next allowed action.';

  return InventoryPurchaseOperatingSummary(
    recommendationRuntimeStateLabel: recommendationRuntimeStateLabel,
    latestSnapshotStateLabel: latestSnapshotStateLabel,
    purchaseOrderCreationReadinessLabel: purchaseOrderCreationReadinessLabel,
    approvalHandoffReadinessLabel: approvalHandoffReadinessLabel,
    receivingReadinessLabel: receivingReadinessLabel,
    selectedPurchaseOrderRuntimeLabel: selectedPurchaseOrderRuntimeLabel,
    nextOperatorAction: nextOperatorAction,
    operatingNarrative: operatingNarrative,
    handoffTarget: runtimeSurface.runtimeClosure.handoffTarget,
    blockedReasons: blockedReasons,
    visibleRecommendationLineCount: recommendationSnapshot.lines.length,
    visiblePurchaseOrderCount: orderSummary.orders.length,
    visibleBlockedReasonCount: blockedReasons.length,
    hasSelectedPurchaseOrder: orderDetail.order != null,
    canConfirmReceipt: runtimeSurface.runtimeClosure.canConfirmReceipt,
    reconciliationSummary: reconciliationSummary,
    actionQueue: actionQueue,
    supplierBottlenecks: supplierBottlenecks,
  );
}

bool _inventoryPurchaseLinePending(Map<String, dynamic> line) {
  final remainingBase =
      (line['remaining_quantity_base'] as num?)?.toDouble() ?? 0;
  final receiptStatus =
      line['receipt_visibility_status']?.toString() ?? 'pending';
  return remainingBase > 0 &&
      receiptStatus != 'received' &&
      receiptStatus != 'confirmed';
}

bool _inventoryPurchaseLineReceived(Map<String, dynamic> line) {
  return !_inventoryPurchaseLinePending(line);
}

bool _inventoryPurchaseLineHighAttention(Map<String, dynamic> line) {
  final receiptStatus =
      line['receipt_visibility_status']?.toString().toLowerCase() ?? 'pending';
  final supplierRisk =
      line['supplier_risk_summary']?.toString().toLowerCase() ?? '';
  return receiptStatus == 'pending' ||
      supplierRisk.contains('price up') ||
      supplierRisk.contains('lead overdue') ||
      supplierRisk.contains('lead tight') ||
      supplierRisk.contains('risk');
}

String _inventoryPurchaseApprovalStateTone(String label) {
  if (label == 'Ready to approve') return 'ready';
  if (label == 'Approved') return 'complete';
  if (label == 'Approval blocked') return 'blocked';
  return 'neutral';
}

String _inventoryPurchaseReceivingStateTone(String label) {
  if (label == 'Ready to receive') return 'ready';
  if (label == 'Received / closed') return 'complete';
  if (label == 'Receiving blocked') return 'blocked';
  return 'neutral';
}

String _inventoryPurchaseApprovalRuntimeNarrative(String orderStatus) {
  switch (orderStatus) {
    case 'submitted':
    case 'office_returned':
      return 'The purchase order is ready for Office review, but POS does not execute approval. Operators can verify readiness and hand off the order to the Office-owned workflow only.';
    case 'office_approved':
    case 'ordered':
    case 'partially_received':
    case 'received':
      return 'Backend truth already shows this order beyond the approval gate. POS keeps the approved state visible and does not replay Office approval execution.';
    case 'office_rejected':
      return 'Office review rejected this order. POS leaves the rejection visible and does not override the Office decision.';
    case 'cancelled':
      return 'This order is cancelled in backend truth, so approval execution stays unavailable from POS.';
    default:
      return 'The order has not reached a stable approval handoff state yet. POS keeps the boundary visible only.';
  }
}

String _inventoryPurchaseReceivingRuntimeNarrative({
  required String orderStatus,
  required double remainingBase,
  required int confirmedReceiptCount,
}) {
  if (orderStatus == 'received' || remainingBase <= 0) {
    return 'Backend truth already shows this order as fully received. POS keeps the final state visible without sending another receipt confirmation.';
  }
  if (_inventoryPurchaseCanConfirmReceipt(
    orderStatus: orderStatus,
    remainingBase: remainingBase,
  )) {
    return 'The receipt confirmation contract exists and can update stock truthfully for the remaining quantity. Use the runtime action only when the inbound goods are physically verified.';
  }
  if (orderStatus == 'submitted' || orderStatus == 'office_returned') {
    return 'Receiving stays blocked until Office approval completes. POS must not mutate stock or create confirmed receipts before that backend state exists.';
  }
  if (orderStatus == 'office_rejected' || orderStatus == 'cancelled') {
    return 'This order is no longer receivable in backend truth, so POS keeps the receiving state blocked.';
  }
  if (confirmedReceiptCount > 0 || orderStatus == 'partially_received') {
    return 'Receipt history already exists, but the current order status still needs backend-truth eligibility before POS can confirm more receiving.';
  }
  return 'Receiving is currently blocked because the backend order state is not receivable.';
}

bool _inventoryPurchaseCanConfirmReceipt({
  required String orderStatus,
  required double remainingBase,
}) {
  if (remainingBase <= 0) {
    return false;
  }
  return orderStatus == 'office_approved' ||
      orderStatus == 'ordered' ||
      orderStatus == 'partially_received';
}

String _inventoryPurchaseReceiptReadinessLabel({
  required String orderStatus,
  required double remainingBase,
  required int confirmedReceiptCount,
}) {
  if (orderStatus == 'received' || remainingBase <= 0) {
    return 'Complete';
  }
  if (orderStatus == 'partially_received' || confirmedReceiptCount > 0) {
    return 'Partial';
  }
  if (orderStatus == 'office_approved' || orderStatus == 'ordered') {
    return 'Ready';
  }
  if (orderStatus == 'cancelled' || orderStatus == 'office_rejected') {
    return 'Blocked';
  }
  return 'Hold';
}

String _inventoryPurchaseReceiptReadinessTone(String label) {
  switch (label) {
    case 'Ready':
      return 'ready';
    case 'Complete':
      return 'complete';
    case 'Blocked':
      return 'blocked';
    case 'Partial':
      return 'watch';
    default:
      return 'neutral';
  }
}

String _inventoryPurchaseReceiptReadinessNarrative({
  required String orderStatus,
  required double remainingBase,
  required int confirmedReceiptCount,
  required bool hasReceiptHistory,
}) {
  if (orderStatus == 'received' || remainingBase <= 0) {
    return 'This purchase order is fully received in the tracked POS scope. No receipt confirmation action is exposed here.';
  }
  if (orderStatus == 'partially_received' || confirmedReceiptCount > 0) {
    return 'Confirmed receipts already exist for this order. Use the remaining quantity signal to understand what is still outstanding without mutating stock.';
  }
  if (orderStatus == 'office_approved' || orderStatus == 'ordered') {
    return hasReceiptHistory
        ? 'Receipt history exists, but confirmed inbound quantity is still incomplete for this order.'
        : 'This order is receipt-ready once goods arrive, but no receipt history is visible yet.';
  }
  if (orderStatus == 'cancelled' || orderStatus == 'office_rejected') {
    return 'This order is not receipt-ready in its current status. Visibility is read-only and does not open approval or correction flows.';
  }
  return 'This order still waits on an earlier workflow step before receipt confirmation becomes relevant. Visibility remains read-only here.';
}

String _inventoryPurchaseReceiptVisibilityStatusLabel({
  required String? latestReceiptStatus,
  required int confirmedReceiptCount,
  required int draftReceiptCount,
}) {
  return (latestReceiptStatus ??
          (confirmedReceiptCount > 0
              ? 'confirmed'
              : draftReceiptCount > 0
              ? 'draft'
              : 'none'))
      .toUpperCase();
}

String _inventoryPurchaseReceiptVisibilityTone(String statusLabel) {
  switch (statusLabel) {
    case 'RECEIVED':
    case 'CONFIRMED':
      return 'complete';
    case 'PARTIALLY_RECEIVED':
      return 'watch';
    case 'DRAFT':
      return 'blocked';
    case 'CANCELLED':
      return 'critical';
    default:
      return 'neutral';
  }
}

String _inventoryPurchaseUnitPriceDriftLabel({
  required double currentUnitPrice,
  required double? previousUnitPrice,
}) {
  if (previousUnitPrice == null || previousUnitPrice <= 0) {
    return 'Price drift unavailable';
  }

  final deltaRatio = (currentUnitPrice - previousUnitPrice) / previousUnitPrice;
  final percent = (deltaRatio.abs() * 100).toStringAsFixed(1);
  if (deltaRatio.abs() < 0.02) {
    return 'Price drift stable ($percent%)';
  }
  if (deltaRatio > 0) {
    return 'Price drift up $percent%';
  }
  return 'Price drift down $percent%';
}

String _inventoryPurchaseLeadTimeRiskLabel({
  required String? requestedDate,
  required int supplierLeadTimeDays,
  required double remainingBase,
  required String orderStatus,
}) {
  if (remainingBase <= 0 || orderStatus == 'received') {
    return 'Lead-time risk complete';
  }
  if (requestedDate == null ||
      requestedDate.isEmpty ||
      supplierLeadTimeDays <= 0) {
    return 'Lead-time risk unavailable';
  }

  final requestedAt = DateTime.tryParse(requestedDate);
  if (requestedAt == null) {
    return 'Lead-time risk unavailable';
  }

  final today = DateTime.now();
  final requestedLocal = DateTime(
    requestedAt.year,
    requestedAt.month,
    requestedAt.day,
  );
  final currentLocal = DateTime(today.year, today.month, today.day);
  final daysUntilRequested = requestedLocal.difference(currentLocal).inDays;

  if (daysUntilRequested < 0) {
    return 'Lead-time risk overdue';
  }
  if (daysUntilRequested < supplierLeadTimeDays) {
    return 'Lead-time risk tight';
  }
  return 'Lead-time risk on track';
}

String _inventoryPurchaseSupplierRiskSummaryLabel({
  required String receiptVisibilityStatus,
  required String unitPriceDriftLabel,
  required String leadTimeRiskLabel,
}) {
  final summaryParts = <String>[];

  if (receiptVisibilityStatus == 'pending' ||
      receiptVisibilityStatus == 'draft') {
    summaryParts.add('receipt pending');
  } else if (receiptVisibilityStatus == 'partially_received') {
    summaryParts.add('receipt partial');
  } else if (receiptVisibilityStatus == 'received' ||
      receiptVisibilityStatus == 'confirmed') {
    summaryParts.add('receipt complete');
  }

  if (unitPriceDriftLabel.contains('up')) {
    summaryParts.add('price up');
  } else if (unitPriceDriftLabel.contains('down')) {
    summaryParts.add('price down');
  } else if (unitPriceDriftLabel.contains('stable')) {
    summaryParts.add('price stable');
  }

  if (leadTimeRiskLabel.contains('overdue')) {
    summaryParts.add('lead overdue');
  } else if (leadTimeRiskLabel.contains('tight')) {
    summaryParts.add('lead tight');
  } else if (leadTimeRiskLabel.contains('on track')) {
    summaryParts.add('lead on track');
  } else if (leadTimeRiskLabel.contains('complete')) {
    summaryParts.add('lead complete');
  }

  if (summaryParts.isEmpty) {
    return 'Supplier risk summary unavailable';
  }
  return 'Supplier risk ${summaryParts.join(' / ')}';
}

int _inventoryPurchaseRuntimeLinePriority(
  Map<String, dynamic> line, {
  required String? requestedDate,
  required String orderStatus,
}) {
  final receiptVisibilityStatus =
      line['receipt_visibility_status']?.toString() ?? 'pending';
  final supplierHistory = List<Map<String, dynamic>>.from(
    line['supplier_history'] as List? ?? const [],
  );
  final latestSupplierHistory = supplierHistory.isEmpty
      ? null
      : supplierHistory.first;
  final currentUnitPrice = (line['unit_price'] as num?)?.toDouble() ?? 0;
  final previousUnitPrice = (latestSupplierHistory?['unit_price'] as num?)
      ?.toDouble();
  final supplierLeadTimeDays =
      ((line['supplier_item'] as Map<String, dynamic>?)?['lead_time_days']
              as num?)
          ?.toInt() ??
      0;
  final remainingBase =
      (line['remaining_quantity_base'] as num?)?.toDouble() ?? 0;
  final unitPriceDriftLabel = _inventoryPurchaseUnitPriceDriftLabel(
    currentUnitPrice: currentUnitPrice,
    previousUnitPrice: previousUnitPrice,
  );
  final leadTimeRiskLabel = _inventoryPurchaseLeadTimeRiskLabel(
    requestedDate: requestedDate,
    supplierLeadTimeDays: supplierLeadTimeDays,
    remainingBase: remainingBase,
    orderStatus: orderStatus,
  );

  if (leadTimeRiskLabel.contains('overdue') ||
      unitPriceDriftLabel.contains('up')) {
    return 4;
  }
  if (receiptVisibilityStatus == 'pending' ||
      leadTimeRiskLabel.contains('tight')) {
    return 3;
  }
  if (receiptVisibilityStatus == 'draft' ||
      unitPriceDriftLabel.contains('down')) {
    return 2;
  }
  if (receiptVisibilityStatus == 'confirmed' ||
      receiptVisibilityStatus == 'received') {
    return 1;
  }
  return 0;
}

List<InventoryPurchaseRuntimeLineContextState>
buildInventoryPurchaseRuntimeLineContexts({
  required List<Map<String, dynamic>> lines,
  required String? requestedDate,
  required String orderStatus,
}) {
  final sorted = List<Map<String, dynamic>>.from(lines);
  sorted.sort((a, b) {
    final priorityCompare =
        _inventoryPurchaseRuntimeLinePriority(
          b,
          requestedDate: requestedDate,
          orderStatus: orderStatus,
        ).compareTo(
          _inventoryPurchaseRuntimeLinePriority(
            a,
            requestedDate: requestedDate,
            orderStatus: orderStatus,
          ),
        );
    if (priorityCompare != 0) {
      return priorityCompare;
    }
    return ((b['remaining_quantity_base'] as num?)?.toDouble() ?? 0).compareTo(
      (a['remaining_quantity_base'] as num?)?.toDouble() ?? 0,
    );
  });

  return sorted.take(3).map((line) {
    final productMap = line['product'] as Map<String, dynamic>?;
    final productName =
        productMap?['name']?.toString() ??
        line['product_id']?.toString() ??
        line['id']?.toString() ??
        '-';
    final orderedBase =
        (line['ordered_quantity_base'] as num?)?.toDouble() ?? 0;
    final expectedBase =
        (line['recommended_quantity_base'] as num?)?.toDouble() ?? 0;
    final receivedBase =
        (line['received_quantity_base'] as num?)?.toDouble() ?? 0;
    final remainingBase =
        (line['remaining_quantity_base'] as num?)?.toDouble() ?? 0;
    final receiptVisibilityStatus =
        line['receipt_visibility_status']?.toString() ?? 'pending';
    final supplierHistory = List<Map<String, dynamic>>.from(
      line['supplier_history'] as List? ?? const [],
    );
    final latestSupplierHistory = supplierHistory.isEmpty
        ? null
        : supplierHistory.first;
    final currentUnitPrice = (line['unit_price'] as num?)?.toDouble() ?? 0;
    final previousUnitPrice = (latestSupplierHistory?['unit_price'] as num?)
        ?.toDouble();
    final supplierLeadTimeDays =
        ((line['supplier_item'] as Map<String, dynamic>?)?['lead_time_days']
                as num?)
            ?.toInt() ??
        0;
    final unitPriceDriftLabel = _inventoryPurchaseUnitPriceDriftLabel(
      currentUnitPrice: currentUnitPrice,
      previousUnitPrice: previousUnitPrice,
    );
    final leadTimeRiskLabel = _inventoryPurchaseLeadTimeRiskLabel(
      requestedDate: requestedDate,
      supplierLeadTimeDays: supplierLeadTimeDays,
      remainingBase: remainingBase,
      orderStatus: orderStatus,
    );
    final riskSummary =
        line['supplier_risk_summary']?.toString() ??
        _inventoryPurchaseSupplierRiskSummaryLabel(
          receiptVisibilityStatus: receiptVisibilityStatus,
          unitPriceDriftLabel: unitPriceDriftLabel,
          leadTimeRiskLabel: leadTimeRiskLabel,
        );
    final priority = _inventoryPurchaseRuntimeLinePriority(
      line,
      requestedDate: requestedDate,
      orderStatus: orderStatus,
    );
    final statusLabel = switch (priority) {
      4 => 'Critical follow-up',
      3 => 'Attention pending',
      2 => 'Watch receiving',
      _ when remainingBase <= 0 => 'Received complete',
      _ => 'Monitoring',
    };
    final statusTone = switch (priority) {
      4 => 'critical',
      3 => 'blocked',
      2 => 'watch',
      _ when remainingBase <= 0 => 'complete',
      _ => 'neutral',
    };
    final narrative = switch (statusLabel) {
      'Critical follow-up' =>
        'This line combines receiving pressure with supplier or lead-time risk and should be reviewed before routine verification.',
      'Attention pending' =>
        'This line is still pending receipt or supplier follow-up, so operators should keep it in the active receiving queue.',
      'Watch receiving' =>
        'This line is moving, but it still needs watch-level review before operators treat it as stable.',
      'Received complete' =>
        'This line already looks complete from backend truth and remains visible for verification only.',
      _ =>
        'This line is currently visible for monitoring, but it does not carry the strongest operational runtime pressure.',
    };

    return InventoryPurchaseRuntimeLineContextState(
      productName: productName,
      orderedBase: orderedBase,
      expectedBase: expectedBase,
      receivedBase: receivedBase,
      remainingBase: remainingBase,
      statusLabel: statusLabel,
      statusTone: statusTone,
      riskSummary: riskSummary,
      narrative: narrative,
    );
  }).toList();
}

int _inventoryPurchaseSupplierImpactCount(List<Map<String, dynamic>> lines) {
  return lines
      .map((line) {
        final supplierItem = line['supplier_item'] as Map<String, dynamic>?;
        return supplierItem?['id']?.toString() ??
            supplierItem?['supplier_sku']?.toString() ??
            line['product_id']?.toString() ??
            line['id']?.toString();
      })
      .whereType<String>()
      .where((value) => value.isNotEmpty)
      .toSet()
      .length;
}

String _inventoryPurchaseOldestWaitingAge(String? requestedDate) {
  if (requestedDate == null || requestedDate.isEmpty) {
    return 'unavailable';
  }
  final requestedAt = DateTime.tryParse(requestedDate);
  if (requestedAt == null) {
    return 'unavailable';
  }
  final today = DateTime.now();
  final requestedLocal = DateTime(
    requestedAt.year,
    requestedAt.month,
    requestedAt.day,
  );
  final currentLocal = DateTime(today.year, today.month, today.day);
  final days = currentLocal.difference(requestedLocal).inDays;
  return days <= 0 ? '0d' : '${days}d';
}

bool _inventoryPurchaseRequestedDateOverdue(String? requestedDate) {
  if (requestedDate == null || requestedDate.isEmpty) {
    return false;
  }
  final requestedAt = DateTime.tryParse(requestedDate);
  if (requestedAt == null) {
    return false;
  }
  final requestedLocal = DateTime(
    requestedAt.year,
    requestedAt.month,
    requestedAt.day,
  );
  final currentLocal = DateTime.now();
  final today = DateTime(
    currentLocal.year,
    currentLocal.month,
    currentLocal.day,
  );
  return requestedLocal.isBefore(today);
}

List<Map<String, dynamic>> buildInventoryPurchaseRuntimeBlockerRows({
  required String orderStatus,
  required String? requestedDate,
  required List<Map<String, dynamic>> lines,
}) {
  final pendingLines = lines.where(_inventoryPurchaseLinePending).toList();
  final highAttentionLines = lines
      .where(_inventoryPurchaseLineHighAttention)
      .toList();
  final overduePendingLines = pendingLines
      .where((line) => _inventoryPurchaseRequestedDateOverdue(requestedDate))
      .toList();

  final rows = <Map<String, dynamic>>[];

  if (pendingLines.isNotEmpty) {
    rows.add({
      'title': 'Supplier follow-up pending',
      'severity': overduePendingLines.isNotEmpty ? 'risk' : 'watch',
      'affected_po_count': 1,
      'impacted_supplier_count': _inventoryPurchaseSupplierImpactCount(
        pendingLines,
      ),
      'oldest_waiting_age': _inventoryPurchaseOldestWaitingAge(requestedDate),
      'narrative':
          '${pendingLines.length} purchase order line(s) still waiting supplier confirmation or receipt progress.',
      'next_hint': overduePendingLines.isNotEmpty
          ? 'Check overdue supplier responses'
          : 'Monitor inbound confirmation',
    });
  }

  if (overduePendingLines.isNotEmpty) {
    rows.add({
      'title': 'Arrival window delayed',
      'severity': 'critical',
      'affected_po_count': 1,
      'impacted_supplier_count': _inventoryPurchaseSupplierImpactCount(
        overduePendingLines,
      ),
      'oldest_waiting_age': _inventoryPurchaseOldestWaitingAge(requestedDate),
      'narrative': 'Receiving delayed beyond expected arrival window.',
      'next_hint': 'Escalate delayed deliveries',
    });
  }

  if (highAttentionLines.isNotEmpty) {
    rows.add({
      'title': 'High-risk supplier lines',
      'severity': 'risk',
      'affected_po_count': 1,
      'impacted_supplier_count': _inventoryPurchaseSupplierImpactCount(
        highAttentionLines,
      ),
      'oldest_waiting_age': _inventoryPurchaseOldestWaitingAge(requestedDate),
      'narrative':
          '${highAttentionLines.length} purchase order line(s) combine receipt pressure with supplier or lead-time risk.',
      'next_hint': 'Review top attention items',
    });
  }

  if (rows.isEmpty) {
    rows.add({
      'title': 'No active receiving blockers',
      'severity': 'healthy',
      'affected_po_count': 0,
      'impacted_supplier_count': 0,
      'oldest_waiting_age': '0d',
      'narrative': orderStatus == 'received'
          ? 'This purchase order already looks fully received from backend truth.'
          : 'Current receiving posture looks healthy from the tracked POS read model.',
      'next_hint': 'Continue read-only monitoring',
    });
  }

  return rows;
}

String _inventoryPurchaseOperationalPhaseLabel({
  required Map<String, dynamic>? order,
  required String orderStatus,
  required double remainingBase,
  required int pendingLineCount,
  required bool canConfirmReceipt,
}) {
  if (order == null) {
    return 'Operational phase selection pending';
  }
  if (orderStatus == 'submitted' || orderStatus == 'office_returned') {
    return 'Operational phase approval handoff';
  }
  if (orderStatus == 'office_rejected' || orderStatus == 'cancelled') {
    return 'Operational phase blocked';
  }
  if (canConfirmReceipt) {
    return 'Operational phase receiving execution';
  }
  if (orderStatus == 'received' || remainingBase <= 0) {
    return 'Operational phase verification';
  }
  if (pendingLineCount > 0) {
    return 'Operational phase receiving follow-up';
  }
  return 'Operational phase runtime review';
}

String _inventoryPurchaseOperationalPhaseTone(String label) {
  if (label.endsWith('execution')) return 'ready';
  if (label.endsWith('handoff')) return 'watch';
  if (label.endsWith('verification')) return 'complete';
  if (label.endsWith('blocked')) return 'blocked';
  if (label.endsWith('follow-up')) return 'watch';
  return 'neutral';
}

String _inventoryPurchaseOperationalPhaseNarrative({
  required String phaseLabel,
  required InventoryPurchaseRuntimeClosureSnapshot runtimeClosure,
}) {
  if (phaseLabel.endsWith('approval handoff')) {
    return 'POS is at the approval-handoff phase. Operators should confirm readiness, review blockers, and hand the order to the Office-owned approval queue.';
  }
  if (phaseLabel.endsWith('receiving execution')) {
    return 'POS is at the receiving-execution phase. Approval truth already exists, so operators can verify inbound goods and use the tracked receipt contract if the remaining quantity is still open.';
  }
  if (phaseLabel.endsWith('verification')) {
    return 'POS is at the verification phase. Runtime execution is effectively closed, and operators should use history and line context to verify the final state.';
  }
  if (phaseLabel.endsWith('blocked')) {
    return 'POS remains in a blocked phase for this order. Operators should use the handoff target and blocked reasons instead of attempting execution.';
  }
  if (phaseLabel.endsWith('follow-up')) {
    return 'POS is in a follow-up phase. Approval may already exist, but operators still need to resolve receiving blockers or pending lines before the order is stable.';
  }
  return runtimeClosure.operatorSummary;
}

String _inventoryPurchaseBlockedStateLabel({
  required Map<String, dynamic>? order,
  required String orderStatus,
  required List<Map<String, dynamic>> blockerRows,
}) {
  if (order == null) {
    return 'Blocked selection pending';
  }
  if (orderStatus == 'office_rejected' || orderStatus == 'cancelled') {
    return 'Blocked hard stop';
  }
  if (blockerRows.any(
    (row) => (row['severity']?.toString() ?? 'healthy') == 'critical',
  )) {
    return 'Blocked escalation open';
  }
  if (blockerRows.any(
    (row) => (row['severity']?.toString() ?? 'healthy') == 'risk',
  )) {
    return 'Blocked follow-up open';
  }
  return 'Blocked none';
}

String _inventoryPurchaseBlockedStateTone(String label) {
  if (label.endsWith('hard stop')) return 'critical';
  if (label.endsWith('escalation open')) return 'blocked';
  if (label.endsWith('follow-up open')) return 'watch';
  if (label.endsWith('selection pending')) return 'neutral';
  return 'complete';
}

String _inventoryPurchaseReadyStateLabel({
  required Map<String, dynamic>? order,
  required InventoryPurchaseRuntimeClosureSnapshot runtimeClosure,
}) {
  if (order == null) {
    return 'Ready no selected order';
  }
  if (runtimeClosure.canConfirmReceipt) {
    return 'Ready confirm receipt';
  }
  if (runtimeClosure.approvalStateLabel == 'Ready to approve') {
    return 'Ready Office handoff';
  }
  if (runtimeClosure.receivingStateLabel == 'Received / closed') {
    return 'Ready verification only';
  }
  return 'Ready waiting backend';
}

String _inventoryPurchaseReadyStateTone(String label) {
  if (label.endsWith('confirm receipt') || label.endsWith('Office handoff')) {
    return 'ready';
  }
  if (label.endsWith('verification only')) return 'complete';
  if (label.endsWith('waiting backend')) return 'watch';
  return 'neutral';
}

String _inventoryPurchaseStaleStateLabel({
  required Map<String, dynamic>? order,
  required String? requestedDate,
  required int pendingLineCount,
  required String? latestReceiptStatus,
}) {
  if (order == null) {
    return 'Stale selection pending';
  }
  if (_inventoryPurchaseRequestedDateOverdue(requestedDate) &&
      pendingLineCount > 0) {
    return 'Stale overdue inbound';
  }
  if ((requestedDate == null || requestedDate.isEmpty) &&
      pendingLineCount > 0) {
    return 'Stale arrival window unknown';
  }
  if (latestReceiptStatus == 'draft' && pendingLineCount > 0) {
    return 'Stale draft receipt open';
  }
  return 'Stale none';
}

String _inventoryPurchaseStaleStateTone(String label) {
  if (label.endsWith('overdue inbound')) return 'critical';
  if (label.endsWith('unknown') || label.endsWith('open')) return 'watch';
  if (label.endsWith('selection pending')) return 'neutral';
  return 'complete';
}

String _inventoryPurchaseNextBestOperatorAction({
  required Map<String, dynamic>? order,
  required InventoryPurchaseRuntimeClosureSnapshot runtimeClosure,
  required List<Map<String, dynamic>> blockerRows,
  required int attentionLineCount,
}) {
  if (order == null) {
    return 'Select a recent purchase order to unlock approval handoff, receiving readiness, blockers, and runtime closure in one operating pass.';
  }
  if (runtimeClosure.approvalStateLabel == 'Ready to approve') {
    return 'Hand off the selected purchase order to Office and keep POS on readiness, blockers, and checklist duty only.';
  }
  if (runtimeClosure.canConfirmReceipt) {
    return 'Physically verify inbound goods, then use Confirm Remaining Receipt only if the tracked receipt contract still matches the remaining quantity.';
  }
  if (blockerRows.any(
    (row) => (row['severity']?.toString() ?? 'healthy') != 'healthy',
  )) {
    return 'Resolve the open receiving blockers first so operators know whether the next step is follow-up, escalation, or verification.';
  }
  if (attentionLineCount > 0) {
    return 'Review the top attention lines before treating the purchase order as stable.';
  }
  if (runtimeClosure.receivingStateLabel == 'Received / closed') {
    return 'Use receipt history and runtime line context to verify the final received state without opening new execution paths.';
  }
  return 'Continue monitoring the current purchase order from the unified runtime surface and follow the handoff target shown by backend truth.';
}

bool _inventoryPurchaseOrderNeedsApproval(String status) {
  return status == 'submitted' || status == 'office_returned';
}

bool _inventoryPurchaseOrderCanReceive(String status) {
  return status == 'office_approved' ||
      status == 'ordered' ||
      status == 'partially_received';
}

bool _inventoryPurchaseOrderIsClosed(String status) {
  return status == 'received' || status == 'cancelled';
}

String _inventoryPurchaseSeverityFromTone(String tone) {
  return switch (tone) {
    'critical' => 'critical',
    'blocked' => 'risk',
    'watch' => 'watch',
    _ => 'healthy',
  };
}

String _inventoryPurchaseActionQueueBucket({
  required String status,
  required String? requestedDate,
  required bool isSelected,
  required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
}) {
  if (isSelected &&
      runtimeSurface.order != null &&
      runtimeSurface.staleStateLabel == 'Stale overdue inbound') {
    return 'Overdue / escalation';
  }
  if (!_inventoryPurchaseOrderIsClosed(status) &&
      _inventoryPurchaseRequestedDateOverdue(requestedDate)) {
    return 'Overdue / escalation';
  }
  if (isSelected &&
      runtimeSurface.order != null &&
      runtimeSurface.runtimeClosure.canConfirmReceipt) {
    return 'Ready to receive now';
  }
  if (_inventoryPurchaseOrderCanReceive(status)) {
    return 'Ready to receive now';
  }
  if (isSelected &&
      runtimeSurface.order != null &&
      runtimeSurface.runtimeClosure.approvalStateLabel == 'Ready to approve') {
    return 'Office handoff now';
  }
  if (_inventoryPurchaseOrderNeedsApproval(status)) {
    return 'Office handoff now';
  }
  return 'Blocked / supplier follow-up';
}

int _inventoryPurchaseActionQueueRank(String bucket) {
  return switch (bucket) {
    'Overdue / escalation' => 4,
    'Ready to receive now' => 3,
    'Office handoff now' => 2,
    _ => 1,
  };
}

String _inventoryPurchaseActionQueueSeverity({
  required String bucket,
  required String status,
  required bool isSelected,
  required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
}) {
  if (isSelected && runtimeSurface.order != null) {
    return _inventoryPurchaseSeverityFromTone(runtimeSurface.blockedStateTone);
  }
  if (bucket == 'Overdue / escalation') return 'critical';
  if (status == 'office_rejected') return 'risk';
  if (bucket == 'Office handoff now') return 'watch';
  if (bucket == 'Ready to receive now') return 'watch';
  return 'risk';
}

String _inventoryPurchaseActionQueueHandoffTarget({
  required String status,
  required bool isSelected,
  required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
}) {
  if (isSelected && runtimeSurface.order != null) {
    return runtimeSurface.runtimeClosure.handoffTarget;
  }
  if (_inventoryPurchaseOrderNeedsApproval(status)) {
    return 'Handoff target Office approval queue';
  }
  if (_inventoryPurchaseOrderCanReceive(status)) {
    return 'Handoff target POS receiving contract';
  }
  if (status == 'office_rejected') {
    return 'Handoff target Office rejection review';
  }
  return 'Handoff target visibility only';
}

String _inventoryPurchaseActionQueueStaleLabel({
  required String status,
  required String? requestedDate,
  required bool isSelected,
  required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
}) {
  if (isSelected && runtimeSurface.order != null) {
    return runtimeSurface.staleStateLabel;
  }
  if (_inventoryPurchaseRequestedDateOverdue(requestedDate) &&
      !_inventoryPurchaseOrderIsClosed(status)) {
    return 'Stale overdue inbound';
  }
  if ((requestedDate == null || requestedDate.isEmpty) &&
      !_inventoryPurchaseOrderIsClosed(status)) {
    return 'Stale arrival window unknown';
  }
  if (status == 'partially_received') {
    return 'Stale draft receipt open';
  }
  return 'Stale none';
}

String _inventoryPurchaseActionQueueNextAction({
  required String status,
  required String bucket,
  required bool isSelected,
  required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
}) {
  if (isSelected && runtimeSurface.order != null) {
    return runtimeSurface.nextBestOperatorAction;
  }
  if (bucket == 'Overdue / escalation') {
    return 'Escalate overdue supplier follow-up and refresh the selected purchase order before deciding on receiving.';
  }
  if (bucket == 'Ready to receive now') {
    return 'Select the purchase order, verify inbound goods physically, then use Confirm Remaining Receipt only if backend truth still shows remaining quantity.';
  }
  if (bucket == 'Office handoff now') {
    return 'Review readiness and hand the purchase order to the Office-owned approval queue.';
  }
  if (status == 'office_rejected') {
    return 'Review the Office rejection outcome and keep both approval execution and receiving blocked inside POS.';
  }
  return 'Review blocked reasons and supplier follow-up before treating the purchase order as stable.';
}

String _inventoryPurchaseActionQueueReason({
  required String status,
  required String bucket,
  required bool isSelected,
  required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
}) {
  if (isSelected && runtimeSurface.order != null) {
    return runtimeSurface.operationalPhaseNarrative;
  }
  if (bucket == 'Overdue / escalation') {
    return 'This purchase order is still open beyond its requested arrival window, so operators should treat it as an escalation item instead of a normal queue entry.';
  }
  if (bucket == 'Ready to receive now') {
    return 'Approval truth already exists in backend state, so this order belongs in the inbound receiving queue rather than the Office handoff queue.';
  }
  if (bucket == 'Office handoff now') {
    return 'This purchase order still depends on Office-owned approval execution, so POS keeps it in a readiness and handoff posture only.';
  }
  if (status == 'office_rejected') {
    return 'Office review rejected this purchase order, so POS keeps the order visible only as a blocked follow-up item.';
  }
  return 'This purchase order still carries unresolved supplier or workflow blockers, so operators should not treat it as execution-ready.';
}

List<InventoryPurchaseActionQueueEntry> buildInventoryPurchaseActionQueue({
  required List<Map<String, dynamic>> orders,
  required String? selectedOrderId,
  required InventoryPurchaseRuntimeSurfaceState runtimeSurface,
}) {
  final openOrders = orders.where((order) {
    final status = order['status']?.toString() ?? 'submitted';
    return !_inventoryPurchaseOrderIsClosed(status);
  }).toList();

  final entries = openOrders.map((order) {
    final orderId = order['id']?.toString() ?? '';
    final status = order['status']?.toString() ?? 'submitted';
    final requestedDate = order['requested_delivery_date']?.toString();
    final supplierMap = order['supplier'] as Map<String, dynamic>?;
    final isSelected =
        selectedOrderId != null &&
        orderId == selectedOrderId &&
        runtimeSurface.order != null;
    final priorityBucket = _inventoryPurchaseActionQueueBucket(
      status: status,
      requestedDate: requestedDate,
      isSelected: isSelected,
      runtimeSurface: runtimeSurface,
    );

    return InventoryPurchaseActionQueueEntry(
      orderId: orderId,
      purchaseOrderNo: order['purchase_order_no']?.toString() ?? '-',
      supplierLabel: supplierMap?['name']?.toString() ?? 'Supplier unavailable',
      priorityBucket: priorityBucket,
      blockerSeverity: _inventoryPurchaseActionQueueSeverity(
        bucket: priorityBucket,
        status: status,
        isSelected: isSelected,
        runtimeSurface: runtimeSurface,
      ),
      handoffTarget: _inventoryPurchaseActionQueueHandoffTarget(
        status: status,
        isSelected: isSelected,
        runtimeSurface: runtimeSurface,
      ),
      staleLabel: _inventoryPurchaseActionQueueStaleLabel(
        status: status,
        requestedDate: requestedDate,
        isSelected: isSelected,
        runtimeSurface: runtimeSurface,
      ),
      nextAction: _inventoryPurchaseActionQueueNextAction(
        status: status,
        bucket: priorityBucket,
        isSelected: isSelected,
        runtimeSurface: runtimeSurface,
      ),
      operatorReason: _inventoryPurchaseActionQueueReason(
        status: status,
        bucket: priorityBucket,
        isSelected: isSelected,
        runtimeSurface: runtimeSurface,
      ),
      isSelected: isSelected,
    );
  }).toList();

  entries.sort((a, b) {
    final rankCompare = _inventoryPurchaseActionQueueRank(
      b.priorityBucket,
    ).compareTo(_inventoryPurchaseActionQueueRank(a.priorityBucket));
    if (rankCompare != 0) {
      return rankCompare;
    }
    if (a.isSelected != b.isSelected) {
      return b.isSelected ? 1 : -1;
    }
    return a.purchaseOrderNo.compareTo(b.purchaseOrderNo);
  });

  return entries;
}

InventoryPurchaseReconciliationSummary
buildInventoryPurchaseReconciliationSummary({
  required int recommendedCount,
  required List<Map<String, dynamic>> orders,
}) {
  final orderedCount = orders.length;
  final receivedCount = orders.where((order) {
    return (order['status']?.toString() ?? 'submitted') == 'received';
  }).length;
  final remainingCount = orders.where((order) {
    final status = order['status']?.toString() ?? 'submitted';
    return !_inventoryPurchaseOrderIsClosed(status);
  }).length;
  final delayedCount = orders.where((order) {
    final status = order['status']?.toString() ?? 'submitted';
    return !_inventoryPurchaseOrderIsClosed(status) &&
        _inventoryPurchaseRequestedDateOverdue(
          order['requested_delivery_date']?.toString(),
        );
  }).length;

  final mismatchIndicatorLabel = () {
    if (delayedCount > 0) {
      return 'Mismatch delayed inbound';
    }
    if (recommendedCount > 0 && orderedCount == 0) {
      return 'Mismatch recommendation not converted';
    }
    if (orders.any((order) {
      return _inventoryPurchaseOrderNeedsApproval(
        order['status']?.toString() ?? 'submitted',
      );
    })) {
      return 'Mismatch approval queue';
    }
    if (remainingCount > 0 && orderedCount > receivedCount) {
      return 'Mismatch receiving backlog';
    }
    return 'Mismatch stable';
  }();

  final mismatchIndicatorTone = switch (mismatchIndicatorLabel) {
    'Mismatch delayed inbound' => 'critical',
    'Mismatch recommendation not converted' => 'watch',
    'Mismatch approval queue' => 'watch',
    'Mismatch receiving backlog' => 'watch',
    _ => 'complete',
  };

  final narrative = delayedCount > 0
      ? '$delayedCount open purchase order(s) are overdue against the requested arrival window, so store reconciliation is not yet stable.'
      : remainingCount > 0
      ? '$remainingCount purchase order(s) still remain open across the current store-scoped queue. Use the action queue and supplier bottlenecks to decide whether the next step is Office handoff, receiving, or escalation.'
      : orderedCount > 0
      ? 'Tracked purchase orders are currently aligned with recommendation conversion and receipt progress from the POS inventory runtime.'
      : 'No purchase-order reconciliation drift is visible yet because the current store-scoped queue has not opened any tracked purchase orders.';

  return InventoryPurchaseReconciliationSummary(
    recommendedCount: recommendedCount,
    orderedCount: orderedCount,
    receivedCount: receivedCount,
    remainingCount: remainingCount,
    delayedCount: delayedCount,
    mismatchIndicatorLabel: mismatchIndicatorLabel,
    mismatchIndicatorTone: mismatchIndicatorTone,
    narrative: narrative,
  );
}

List<InventoryPurchaseSupplierBottleneckState>
buildInventoryPurchaseSupplierBottlenecks({
  required List<Map<String, dynamic>> orders,
}) {
  final openOrders = orders.where((order) {
    final status = order['status']?.toString() ?? 'submitted';
    return !_inventoryPurchaseOrderIsClosed(status);
  }).toList();

  if (openOrders.isEmpty) {
    return const [
      InventoryPurchaseSupplierBottleneckState(
        supplierLabel: 'No supplier bottleneck visible',
        affectedPoCount: 0,
        oldestWaitingAge: '0d',
        blockedReasonCluster: 'Stable queue',
        nextFollowUpTarget: 'Continue monitoring recent purchase orders',
        severity: 'healthy',
        narrative:
            'No open supplier bottleneck is currently visible in the tracked POS purchase-order queue.',
      ),
    ];
  }

  final grouped = <String, List<Map<String, dynamic>>>{};
  for (final order in openOrders) {
    final supplierMap = order['supplier'] as Map<String, dynamic>?;
    final supplierLabel =
        supplierMap?['name']?.toString() ?? 'Supplier unavailable';
    grouped.putIfAbsent(supplierLabel, () => []).add(order);
  }

  final rows = grouped.entries.map((entry) {
    final supplierOrders = entry.value;
    final statuses = supplierOrders
        .map((order) => order['status']?.toString() ?? 'submitted')
        .toList();
    final oldestRequestedDate = supplierOrders
        .map((order) => order['requested_delivery_date']?.toString())
        .whereType<String>()
        .where((value) => value.isNotEmpty)
        .fold<String?>(null, (earliest, current) {
          if (earliest == null) return current;
          return current.compareTo(earliest) < 0 ? current : earliest;
        });
    final hasOverdue = supplierOrders.any((order) {
      return _inventoryPurchaseRequestedDateOverdue(
        order['requested_delivery_date']?.toString(),
      );
    });
    final blockedReasonCluster = () {
      if (hasOverdue) return 'Delayed inbound cluster';
      if (statuses.contains('office_rejected')) {
        return 'Office rejection cluster';
      }
      if (statuses.any(_inventoryPurchaseOrderNeedsApproval)) {
        return 'Approval handoff cluster';
      }
      if (statuses.any(_inventoryPurchaseOrderCanReceive)) {
        return 'Receiving follow-up cluster';
      }
      return 'Stable queue';
    }();
    final severity = () {
      if (hasOverdue) return 'critical';
      if (statuses.contains('office_rejected')) return 'risk';
      if (statuses.any(_inventoryPurchaseOrderNeedsApproval)) return 'watch';
      if (statuses.any(_inventoryPurchaseOrderCanReceive)) return 'watch';
      return 'healthy';
    }();
    final nextFollowUpTarget = () {
      if (hasOverdue) return 'Escalate supplier ETA and receiving follow-up';
      if (statuses.contains('office_rejected')) {
        return 'Review Office rejection and supplier response';
      }
      if (statuses.any(_inventoryPurchaseOrderNeedsApproval)) {
        return 'Hand off queued orders to Office approval';
      }
      if (statuses.any(_inventoryPurchaseOrderCanReceive)) {
        return 'Verify inbound goods and open the tracked receipt path';
      }
      return 'Continue monitoring supplier queue';
    }();

    return InventoryPurchaseSupplierBottleneckState(
      supplierLabel: entry.key,
      affectedPoCount: supplierOrders.length,
      oldestWaitingAge: _inventoryPurchaseOldestWaitingAge(oldestRequestedDate),
      blockedReasonCluster: blockedReasonCluster,
      nextFollowUpTarget: nextFollowUpTarget,
      severity: severity,
      narrative:
          '${supplierOrders.length} open purchase order(s) currently depend on this supplier cluster. Use the next follow-up target before treating the queue as stable.',
    );
  }).toList();

  rows.sort((a, b) {
    final severityOrder = {'critical': 4, 'risk': 3, 'watch': 2, 'healthy': 1};
    final severityCompare = (severityOrder[b.severity] ?? 0).compareTo(
      severityOrder[a.severity] ?? 0,
    );
    if (severityCompare != 0) {
      return severityCompare;
    }
    return b.affectedPoCount.compareTo(a.affectedPoCount);
  });

  return rows.take(4).toList();
}

InventoryPurchaseReceivingSafetyState
buildInventoryPurchaseReceivingSafetyState({
  required Map<String, dynamic>? order,
  required InventoryPurchaseRuntimeClosureSnapshot runtimeClosure,
  required InventoryPurchaseReceivingRuntimeState receivingRuntime,
}) {
  if (order == null) {
    return const InventoryPurchaseReceivingSafetyState(
      lastAttemptLabel: 'Last attempt no selected purchase order',
      retryDisciplineLabel:
          'Retry discipline select a tracked purchase order first',
      unknownOutcomeLabel: 'Unknown outcome not applicable before selection',
      followUpGuidanceLabel:
          'Follow-up load and select one purchase order first',
      tone: 'neutral',
      narrative:
          'Receiving safety remains closed until a tracked purchase order is loaded into the POS runtime surface.',
    );
  }

  if (receivingRuntime.isSubmitting) {
    return const InventoryPurchaseReceivingSafetyState(
      lastAttemptLabel: 'Last attempt submitting now',
      retryDisciplineLabel:
          'Retry discipline do not retry while submission is in flight',
      unknownOutcomeLabel:
          'Unknown outcome refresh the selected purchase order if the request stalls',
      followUpGuidanceLabel:
          'Follow-up wait for backend truth, then refresh detail and receipt history',
      tone: 'watch',
      narrative:
          'A tracked receipt confirmation is currently in flight. Avoid repeated submissions until backend truth settles and the selected purchase order has been refreshed.',
    );
  }

  final lastResult = receivingRuntime.result;
  if (lastResult == null) {
    if (runtimeClosure.canConfirmReceipt) {
      return const InventoryPurchaseReceivingSafetyState(
        lastAttemptLabel: 'Last attempt none yet',
        retryDisciplineLabel:
            'Retry discipline single submit only, then refresh first',
        unknownOutcomeLabel:
            'Unknown outcome handling refresh selected order and receipt history if the dialog closes unexpectedly',
        followUpGuidanceLabel:
            'Follow-up physically verify inbound goods before using Confirm Remaining Receipt',
        tone: 'ready',
        narrative:
            'The tracked receipt contract is ready, but operators should still follow a refresh-first discipline between attempts so duplicate receiving fear does not turn into accidental re-submission.',
      );
    }
    if (runtimeClosure.receivingStateLabel == 'Received / closed') {
      return const InventoryPurchaseReceivingSafetyState(
        lastAttemptLabel: 'Last attempt not needed',
        retryDisciplineLabel: 'Retry discipline refresh-only verification',
        unknownOutcomeLabel: 'Unknown outcome not visible in a closed state',
        followUpGuidanceLabel:
            'Follow-up use receipt history and runtime line context for verification',
        tone: 'complete',
        narrative:
            'Backend truth already shows the purchase order as received, so POS keeps the path in verification mode and does not expose another receipt mutation attempt.',
      );
    }
    return InventoryPurchaseReceivingSafetyState(
      lastAttemptLabel: 'Last attempt blocked',
      retryDisciplineLabel:
          'Retry discipline wait for backend readiness before retrying',
      unknownOutcomeLabel:
          'Unknown outcome handling is not active while the path is blocked',
      followUpGuidanceLabel:
          'Follow-up use blocked reasons and handoff target before reopening receipt execution',
      tone: 'blocked',
      narrative:
          'Receiving is not currently execution-ready. ${runtimeClosure.blockedReasons.join(' ')}',
    );
  }

  switch (lastResult.kind) {
    case InventoryPurchaseRuntimeResultKind.success:
      return InventoryPurchaseReceivingSafetyState(
        lastAttemptLabel: 'Last attempt ${lastResult.title}',
        retryDisciplineLabel: lastResult.title == 'Received and closed'
            ? 'Retry discipline do not retry, refresh-only verification'
            : 'Retry discipline refresh selected order before any second confirmation',
        unknownOutcomeLabel: lastResult.title == 'Received and closed'
            ? 'Unknown outcome not visible after backend success'
            : 'Unknown outcome handling stop and re-check remaining quantity before any repeat',
        followUpGuidanceLabel:
            'Follow-up refresh detail and receipt history before the next operator step',
        tone: lastResult.title == 'Received and closed' ? 'complete' : 'ready',
        narrative:
            'Backend truth accepted the tracked receipt action. Refresh the selected purchase order and receipt history before any further operator decision so the next step still follows persisted quantities.',
      );
    case InventoryPurchaseRuntimeResultKind.cancelled:
      return InventoryPurchaseReceivingSafetyState(
        lastAttemptLabel: 'Last attempt ${lastResult.title}',
        retryDisciplineLabel:
            'Retry discipline safe to reopen only after re-checking inbound goods',
        unknownOutcomeLabel:
            'Unknown outcome not present because no backend mutation was sent',
        followUpGuidanceLabel:
            'Follow-up reopen the dialog only if physical verification is complete',
        tone: 'watch',
        narrative: lastResult.message,
      );
    case InventoryPurchaseRuntimeResultKind.blocked:
      return InventoryPurchaseReceivingSafetyState(
        lastAttemptLabel: 'Last attempt ${lastResult.title}',
        retryDisciplineLabel:
            'Retry discipline do not retry until backend blocked reasons clear',
        unknownOutcomeLabel:
            'Unknown outcome handling stays closed while backend truth blocks receiving',
        followUpGuidanceLabel:
            'Follow-up use readiness, blockers, and handoff guidance instead of forcing receipt execution',
        tone: 'blocked',
        narrative: lastResult.message,
      );
    case InventoryPurchaseRuntimeResultKind.failure:
      return InventoryPurchaseReceivingSafetyState(
        lastAttemptLabel: 'Last attempt ${lastResult.title}',
        retryDisciplineLabel:
            'Retry discipline refresh selected order and receipt history before retrying',
        unknownOutcomeLabel:
            'Unknown outcome handling treat backend receipt state as unknown until refresh proves the remaining quantity is still open',
        followUpGuidanceLabel:
            'Follow-up refresh first, then retry only if remaining quantity and latest receipt history still justify another confirmation',
        tone: 'risk',
        narrative:
            'A failure or timeout can leave operators uncertain about whether backend truth changed. Refresh the selected purchase order and receipt history first so a second confirmation is never guessed from stale UI state.',
      );
    case InventoryPurchaseRuntimeResultKind.idle:
      return const InventoryPurchaseReceivingSafetyState(
        lastAttemptLabel: 'Last attempt idle',
        retryDisciplineLabel:
            'Retry discipline refresh selected order before acting',
        unknownOutcomeLabel:
            'Unknown outcome not visible while runtime is idle',
        followUpGuidanceLabel:
            'Follow-up use readiness and blocked states to choose the next allowed step',
        tone: 'neutral',
        narrative:
            'No receiving attempt is currently active, so POS keeps the receiving path in a read-model posture only.',
      );
  }
}

final inventoryPurchaseRuntimeSurfaceProvider =
    Provider<InventoryPurchaseRuntimeSurfaceState>((ref) {
      final orderDetail = ref.watch(inventoryPurchaseOrderDetailProvider);
      final approvalRuntime = ref.watch(
        inventoryPurchaseApprovalRuntimeProvider,
      );
      final receivingRuntime = ref.watch(
        inventoryPurchaseReceivingRuntimeProvider,
      );
      final order = orderDetail.order;
      final orderStatus = order?['status']?.toString() ?? 'submitted';
      final requestedDate = order?['requested_delivery_date']?.toString();
      final expectedBase =
          (order?['total_expected_quantity_base'] as num?)?.toDouble() ?? 0;
      final receivedBase =
          (order?['total_received_quantity_base'] as num?)?.toDouble() ?? 0;
      final acceptedBase =
          (order?['total_accepted_quantity_base'] as num?)?.toDouble() ?? 0;
      final rejectedBase =
          (order?['total_rejected_quantity_base'] as num?)?.toDouble() ?? 0;
      final remainingBase =
          (order?['total_remaining_quantity_base'] as num?)?.toDouble() ?? 0;
      final confirmedReceiptCount =
          (order?['confirmed_receipt_count'] as num?)?.toInt() ?? 0;
      final draftReceiptCount =
          (order?['draft_receipt_count'] as num?)?.toInt() ?? 0;
      final cancelledReceiptCount =
          (order?['cancelled_receipt_count'] as num?)?.toInt() ?? 0;
      final latestReceipt = orderDetail.receipts.isEmpty
          ? null
          : orderDetail.receipts.first;
      final latestReceiptStatus =
          order?['latest_receipt_status']?.toString() ??
          latestReceipt?['status']?.toString();
      final latestReceiptAt = DateTime.tryParse(
        order?['latest_receipt_at']?.toString() ??
            latestReceipt?['received_at']?.toString() ??
            latestReceipt?['created_at']?.toString() ??
            '',
      )?.toLocal();
      final receivedLineCount = orderDetail.lines
          .where(_inventoryPurchaseLineReceived)
          .length;
      final pendingLineCount = orderDetail.lines
          .where(_inventoryPurchaseLinePending)
          .length;
      final attentionLineCount = orderDetail.lines
          .where(_inventoryPurchaseLineHighAttention)
          .length;
      final blockedLineCount = attentionLineCount;
      final blockerRows = buildInventoryPurchaseRuntimeBlockerRows(
        orderStatus: orderStatus,
        requestedDate: requestedDate,
        lines: orderDetail.lines,
      );
      final runtimeClosure = buildInventoryPurchaseRuntimeClosureSnapshot(
        order: order,
        approvalRuntime: approvalRuntime,
        receivingRuntime: receivingRuntime,
        blockedLineCount: blockedLineCount,
        pendingLineCount: pendingLineCount,
        attentionLineCount: attentionLineCount,
      );
      final receivingReadinessLabel = _inventoryPurchaseReceiptReadinessLabel(
        orderStatus: orderStatus,
        remainingBase: remainingBase,
        confirmedReceiptCount: confirmedReceiptCount,
      );
      final lineContexts = buildInventoryPurchaseRuntimeLineContexts(
        lines: orderDetail.lines,
        requestedDate: requestedDate,
        orderStatus: orderStatus,
      );
      final operationalPhaseLabel = _inventoryPurchaseOperationalPhaseLabel(
        order: order,
        orderStatus: orderStatus,
        remainingBase: remainingBase,
        pendingLineCount: pendingLineCount,
        canConfirmReceipt: runtimeClosure.canConfirmReceipt,
      );
      final receiptVisibilityStatusLabel =
          _inventoryPurchaseReceiptVisibilityStatusLabel(
            latestReceiptStatus: latestReceiptStatus,
            confirmedReceiptCount: confirmedReceiptCount,
            draftReceiptCount: draftReceiptCount,
          );
      final receiptVisibilityNarrative =
          'Receipt visibility remains ${receiptVisibilityStatusLabel.toLowerCase()} in POS. Use the readiness and blocker signals to decide whether operators should monitor, hand off, or use the tracked receipt confirmation path.';
      final receivedLineSummaryLabel = receivedLineCount <= 0
          ? 'Received lines 0'
          : 'Received lines $receivedLineCount / ${orderDetail.lines.length}';
      final remainingLineSummaryLabel = pendingLineCount <= 0
          ? 'Remaining lines clear'
          : 'Remaining lines $pendingLineCount / ${remainingBase.toStringAsFixed(3)} base';
      final receivingSafety = buildInventoryPurchaseReceivingSafetyState(
        order: order,
        runtimeClosure: runtimeClosure,
        receivingRuntime: receivingRuntime,
      );

      return InventoryPurchaseRuntimeSurfaceState(
        order: order,
        orderStatus: orderStatus,
        requestedDate: requestedDate,
        remainingBase: remainingBase,
        expectedBase: expectedBase,
        receivedBase: receivedBase,
        acceptedBase: acceptedBase,
        rejectedBase: rejectedBase,
        confirmedReceiptCount: confirmedReceiptCount,
        draftReceiptCount: draftReceiptCount,
        cancelledReceiptCount: cancelledReceiptCount,
        receivedLineCount: receivedLineCount,
        blockedLineCount: blockedLineCount,
        pendingLineCount: pendingLineCount,
        attentionLineCount: attentionLineCount,
        latestReceiptStatus: latestReceiptStatus,
        latestReceiptAt: latestReceiptAt,
        operationalPhaseLabel: operationalPhaseLabel,
        operationalPhaseTone: _inventoryPurchaseOperationalPhaseTone(
          operationalPhaseLabel,
        ),
        operationalPhaseNarrative: _inventoryPurchaseOperationalPhaseNarrative(
          phaseLabel: operationalPhaseLabel,
          runtimeClosure: runtimeClosure,
        ),
        approvalStateTone: _inventoryPurchaseApprovalStateTone(
          runtimeClosure.approvalStateLabel,
        ),
        approvalNarrative: _inventoryPurchaseApprovalRuntimeNarrative(
          orderStatus,
        ),
        receivingStateTone: _inventoryPurchaseReceivingStateTone(
          runtimeClosure.receivingStateLabel,
        ),
        receivingNarrative: _inventoryPurchaseReceivingRuntimeNarrative(
          orderStatus: orderStatus,
          remainingBase: remainingBase,
          confirmedReceiptCount: confirmedReceiptCount,
        ),
        receivingReadinessLabel: receivingReadinessLabel,
        receivingReadinessTone: _inventoryPurchaseReceiptReadinessTone(
          receivingReadinessLabel,
        ),
        receivingReadinessNarrative:
            _inventoryPurchaseReceiptReadinessNarrative(
              orderStatus: orderStatus,
              remainingBase: remainingBase,
              confirmedReceiptCount: confirmedReceiptCount,
              hasReceiptHistory: orderDetail.receipts.isNotEmpty,
            ),
        receiptVisibilityStatusLabel: receiptVisibilityStatusLabel,
        receiptVisibilityStatusTone: _inventoryPurchaseReceiptVisibilityTone(
          receiptVisibilityStatusLabel,
        ),
        receiptVisibilityNarrative: receiptVisibilityNarrative,
        readyStateLabel: _inventoryPurchaseReadyStateLabel(
          order: order,
          runtimeClosure: runtimeClosure,
        ),
        readyStateTone: _inventoryPurchaseReadyStateTone(
          _inventoryPurchaseReadyStateLabel(
            order: order,
            runtimeClosure: runtimeClosure,
          ),
        ),
        blockedStateLabel: _inventoryPurchaseBlockedStateLabel(
          order: order,
          orderStatus: orderStatus,
          blockerRows: blockerRows,
        ),
        blockedStateTone: _inventoryPurchaseBlockedStateTone(
          _inventoryPurchaseBlockedStateLabel(
            order: order,
            orderStatus: orderStatus,
            blockerRows: blockerRows,
          ),
        ),
        staleStateLabel: _inventoryPurchaseStaleStateLabel(
          order: order,
          requestedDate: requestedDate,
          pendingLineCount: pendingLineCount,
          latestReceiptStatus: latestReceiptStatus,
        ),
        staleStateTone: _inventoryPurchaseStaleStateTone(
          _inventoryPurchaseStaleStateLabel(
            order: order,
            requestedDate: requestedDate,
            pendingLineCount: pendingLineCount,
            latestReceiptStatus: latestReceiptStatus,
          ),
        ),
        nextBestOperatorAction: _inventoryPurchaseNextBestOperatorAction(
          order: order,
          runtimeClosure: runtimeClosure,
          blockerRows: blockerRows,
          attentionLineCount: attentionLineCount,
        ),
        receivedLineSummaryLabel: receivedLineSummaryLabel,
        remainingLineSummaryLabel: remainingLineSummaryLabel,
        blockerRows: blockerRows,
        lineContexts: lineContexts,
        receivingSafety: receivingSafety,
        runtimeClosure: runtimeClosure,
      );
    });

final inventoryPurchaseOperatingSummaryProvider =
    Provider<InventoryPurchaseOperatingSummary>((ref) {
      final overview = ref.watch(inventoryPurchaseOverviewProvider);
      final recommendationRun = ref.watch(
        inventoryPurchaseRecommendationRunProvider,
      );
      final recommendationSnapshot = ref.watch(
        inventoryPurchaseRecommendationSnapshotProvider,
      );
      final orderCreation = ref.watch(inventoryPurchaseOrderCreationProvider);
      final orderSummary = ref.watch(inventoryPurchaseOrderSummaryProvider);
      final orderDetail = ref.watch(inventoryPurchaseOrderDetailProvider);
      final runtimeSurface = ref.watch(inventoryPurchaseRuntimeSurfaceProvider);

      return buildInventoryPurchaseOperatingSummary(
        overview: overview,
        recommendationRun: recommendationRun,
        recommendationSnapshot: recommendationSnapshot,
        orderCreation: orderCreation,
        orderSummary: orderSummary,
        orderDetail: orderDetail,
        runtimeSurface: runtimeSurface,
      );
    });

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
