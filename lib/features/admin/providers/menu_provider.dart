import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/menu_service.dart';

class MenuState {
  const MenuState({
    this.categories = const AsyncValue.loading(),
    this.items = const AsyncValue.loading(),
    this.selectedCategoryId,
    this.error,
  });

  final AsyncValue<List<Map<String, dynamic>>> categories;
  final AsyncValue<List<Map<String, dynamic>>> items;
  final String? selectedCategoryId;
  final String? error;

  MenuState copyWith({
    AsyncValue<List<Map<String, dynamic>>>? categories,
    AsyncValue<List<Map<String, dynamic>>>? items,
    String? selectedCategoryId,
    String? error,
    bool clearSelectedCategory = false,
    bool clearError = false,
  }) {
    return MenuState(
      categories: categories ?? this.categories,
      items: items ?? this.items,
      selectedCategoryId: clearSelectedCategory
          ? null
          : (selectedCategoryId ?? this.selectedCategoryId),
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class MenuNotifier extends StateNotifier<MenuState> {
  MenuNotifier(this.storeId) : super(const MenuState()) {
    fetchAll();
  }

  final String storeId;

  String _mapMenuError(Object error, String fallback) {
    if (error is! PostgrestException) {
      return fallback;
    }

    final message = error.message;
    if (message.contains('ADMIN_MUTATION_FORBIDDEN')) {
      return 'No permission to change menus.';
    }
    if (message.contains('MENU_CATEGORY_NAME_REQUIRED')) {
      return 'Enter a category name.';
    }
    if (message.contains('MENU_ITEM_NAME_REQUIRED')) {
      return 'Enter a menu name.';
    }
    if (message.contains('MENU_CATEGORY_NOT_FOUND')) {
      return 'Re-select a category.';
    }
    if (message.contains('MENU_ITEM_NOT_FOUND')) {
      return 'Reload menus and try again.';
    }
    if (message.contains('duplicate key value') || message.contains('23505')) {
      return 'An item with the same sort or name already exists.';
    }

    return fallback;
  }

  Future<void> fetchAll() async {
    await Future.wait([fetchCategories(), fetchItems()]);
  }

  Future<void> fetchCategories() async {
    state = state.copyWith(categories: const AsyncValue.loading());
    try {
      final categories = await menuService.fetchCategories(storeId);

      final selectedId = state.selectedCategoryId;
      final hasSelectedId =
          selectedId != null &&
          categories.any((category) => category['id'].toString() == selectedId);

      state = state.copyWith(
        categories: AsyncValue.data(categories),
        selectedCategoryId: categories.isNotEmpty
            ? (hasSelectedId ? selectedId : categories.first['id'].toString())
            : null,
        clearSelectedCategory: categories.isEmpty,
        clearError: true,
      );
    } catch (error, stackTrace) {
      state = state.copyWith(categories: AsyncValue.error(error, stackTrace));
    }
  }

  Future<void> fetchItems() async {
    state = state.copyWith(items: const AsyncValue.loading());
    try {
      final items = await menuService.fetchItems(storeId);
      state = state.copyWith(items: AsyncValue.data(items), clearError: true);
    } catch (error, stackTrace) {
      state = state.copyWith(items: AsyncValue.error(error, stackTrace));
    }
  }

  void selectCategory(String categoryId) {
    state = state.copyWith(selectedCategoryId: categoryId);
  }

  Future<bool> addCategory(String name) async {
    try {
      final currentCategories = state.categories.valueOrNull ?? [];
      await menuService.addCategory(
        storeId: storeId,
        name: name,
        sortOrder: currentCategories.length,
      );
      await fetchCategories();
      state = state.copyWith(clearError: true);
      return true;
    } catch (error, _) {
      state = state.copyWith(error: _mapMenuError(error, 'Failed to add category.'));
      return false;
    }
  }

  Future<bool> addMenuItem(String categoryId, String name, double price) async {
    try {
      final currentItems = state.items.valueOrNull ?? [];
      final sortOrder = currentItems
          .where((item) => item['category_id'].toString() == categoryId)
          .length;

      await menuService.addMenuItem(
        storeId: storeId,
        categoryId: categoryId,
        name: name,
        price: price,
        sortOrder: sortOrder,
      );
      await fetchItems();
      state = state.copyWith(clearError: true);
      return true;
    } catch (error, _) {
      state = state.copyWith(error: _mapMenuError(error, 'Failed to add menu.'));
      return false;
    }
  }

  Future<bool> toggleAvailability(String itemId, bool isAvailable) async {
    try {
      await menuService.toggleAvailability(itemId, isAvailable);
      await fetchItems();
      state = state.copyWith(clearError: true);
      return true;
    } catch (error, _) {
      state = state.copyWith(error: _mapMenuError(error, 'Failed to change menu status.'));
      return false;
    }
  }

  Future<bool> updateMenuItem({
    required String itemId,
    required String name,
    required double price,
  }) async {
    try {
      await menuService.updateMenuItem(
        itemId: itemId,
        name: name,
        price: price,
      );
      await fetchItems();
      state = state.copyWith(clearError: true);
      return true;
    } catch (error, _) {
      state = state.copyWith(error: _mapMenuError(error, 'Failed to update menu.'));
      return false;
    }
  }
}

final menuProvider = StateNotifierProvider.autoDispose
    .family<MenuNotifier, MenuState, String>(
      (ref, storeId) => MenuNotifier(storeId),
    );
