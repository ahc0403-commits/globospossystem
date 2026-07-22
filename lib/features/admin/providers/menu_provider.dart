import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
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
    if (message.contains('MENU_CATEGORY_NOT_EMPTY')) {
      return 'Remove or move every menu in this category before deleting it.';
    }
    if (message.contains('MENU_ITEM_NOT_FOUND')) {
      return 'Reload menus and try again.';
    }
    if (message.contains('MENU_IMAGE_')) {
      return 'The menu photo could not be saved. Choose another image and try again.';
    }
    if (message.contains('MENU_IMPORT_ITEM_EXISTS')) {
      return 'A menu with the same name already exists in that category.';
    }
    if (message.contains('MENU_IMPORT_CATEGORY_INACTIVE')) {
      return 'An imported category is inactive. Activate it before importing.';
    }
    if (message.contains('MENU_IMPORT_CATEGORY_AMBIGUOUS')) {
      return 'Duplicate category names already exist. Merge them before importing.';
    }
    if (message.contains('MENU_IMPORT_')) {
      return 'The Excel menu data is invalid. Review the file and try again.';
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

  Future<bool> addCategory({
    required String nameKo,
    required String nameVi,
    required String nameEn,
  }) async {
    try {
      final currentCategories = state.categories.valueOrNull ?? [];
      await menuService.addCategory(
        storeId: storeId,
        nameKo: nameKo,
        nameVi: nameVi,
        nameEn: nameEn,
        sortOrder: currentCategories.length,
      );
      await fetchCategories();
      state = state.copyWith(clearError: true);
      return true;
    } catch (error, _) {
      state = state.copyWith(
        error: _mapMenuError(error, 'Failed to add category.'),
      );
      return false;
    }
  }

  Future<bool> updateCategory({
    required String categoryId,
    required String nameKo,
    required String nameVi,
    required String nameEn,
  }) async {
    try {
      await menuService.updateCategory(
        categoryId: categoryId,
        nameKo: nameKo,
        nameVi: nameVi,
        nameEn: nameEn,
      );
      await fetchCategories();
      state = state.copyWith(clearError: true);
      return true;
    } catch (error, _) {
      state = state.copyWith(
        error: _mapMenuError(error, 'Failed to update category.'),
      );
      return false;
    }
  }

  Future<bool> deleteCategory(String categoryId) async {
    try {
      await menuService.deleteCategory(categoryId);
      await fetchCategories();
      state = state.copyWith(clearError: true);
      return true;
    } catch (error, _) {
      state = state.copyWith(
        error: _mapMenuError(error, 'Failed to delete category.'),
      );
      return false;
    }
  }

  Future<bool> addMenuItem({
    required String categoryId,
    required String nameKo,
    required String nameVi,
    required String nameEn,
    required double price,
  }) async {
    try {
      final currentItems = state.items.valueOrNull ?? [];
      final sortOrder = currentItems
          .where((item) => item['category_id'].toString() == categoryId)
          .length;

      await menuService.addMenuItem(
        storeId: storeId,
        categoryId: categoryId,
        nameKo: nameKo,
        nameVi: nameVi,
        nameEn: nameEn,
        price: price,
        sortOrder: sortOrder,
      );
      await fetchItems();
      state = state.copyWith(clearError: true);
      return true;
    } catch (error, _) {
      state = state.copyWith(
        error: _mapMenuError(error, 'Failed to add menu.'),
      );
      return false;
    }
  }

  Future<bool> addMenuItemWithPhoto({
    required String categoryId,
    required String nameKo,
    required String nameVi,
    required String nameEn,
    required double price,
    required XFile photo,
  }) async {
    Map<String, dynamic>? created;
    MenuImageUploadResult? uploaded;
    try {
      final currentItems = state.items.valueOrNull ?? [];
      final sortOrder = currentItems
          .where((item) => item['category_id'].toString() == categoryId)
          .length;
      created = await menuService.addMenuItem(
        storeId: storeId,
        categoryId: categoryId,
        nameKo: nameKo,
        nameVi: nameVi,
        nameEn: nameEn,
        price: price,
        sortOrder: sortOrder,
      );
      final itemId = created['id']?.toString() ?? '';
      if (itemId.isEmpty) {
        throw StateError('MENU_ITEM_ID_REQUIRED');
      }

      uploaded = await menuService.uploadMenuImage(
        storeId: storeId,
        itemId: itemId,
        file: photo,
      );
      await menuService.setMenuItemImage(
        itemId: itemId,
        imageUrl: uploaded.publicUrl,
        storagePath: uploaded.storagePath,
      );
      await fetchItems();
      state = state.copyWith(clearError: true);
      return true;
    } catch (error, _) {
      if (uploaded != null) {
        try {
          await menuService.removeMenuImageObject(uploaded.storagePath);
        } catch (_) {}
      }
      final itemId = created?['id']?.toString();
      if (itemId != null && itemId.isNotEmpty) {
        try {
          await menuService.deleteMenuItem(itemId);
        } catch (_) {}
      }
      state = state.copyWith(
        error: _mapMenuError(error, 'Failed to add the menu photo.'),
      );
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
      state = state.copyWith(
        error: _mapMenuError(error, 'Failed to change menu status.'),
      );
      return false;
    }
  }

  Future<bool> togglePublicVisibility(
    String itemId,
    bool isVisiblePublic,
  ) async {
    try {
      await menuService.togglePublicVisibility(itemId, isVisiblePublic);
      await fetchItems();
      state = state.copyWith(clearError: true);
      return true;
    } catch (error, _) {
      state = state.copyWith(
        error: _mapMenuError(error, 'Failed to change QR menu visibility.'),
      );
      return false;
    }
  }

  Future<bool> updateMenuItem({
    required String itemId,
    required String nameKo,
    required String nameVi,
    required String nameEn,
    required double price,
  }) async {
    try {
      await menuService.updateMenuItem(
        itemId: itemId,
        nameKo: nameKo,
        nameVi: nameVi,
        nameEn: nameEn,
        price: price,
      );
      await fetchItems();
      state = state.copyWith(clearError: true);
      return true;
    } catch (error, _) {
      state = state.copyWith(
        error: _mapMenuError(error, 'Failed to update menu.'),
      );
      return false;
    }
  }

  Future<bool> replaceMenuItemImage({
    required String itemId,
    required XFile photo,
    String? previousStoragePath,
  }) async {
    MenuImageUploadResult? uploaded;
    try {
      uploaded = await menuService.uploadMenuImage(
        storeId: storeId,
        itemId: itemId,
        file: photo,
      );
      await menuService.setMenuItemImage(
        itemId: itemId,
        imageUrl: uploaded.publicUrl,
        storagePath: uploaded.storagePath,
      );
      if (previousStoragePath != null && previousStoragePath.isNotEmpty) {
        try {
          await menuService.removeMenuImageObject(previousStoragePath);
        } catch (_) {}
      }
      await fetchItems();
      state = state.copyWith(clearError: true);
      return true;
    } catch (error, _) {
      if (uploaded != null) {
        try {
          await menuService.removeMenuImageObject(uploaded.storagePath);
        } catch (_) {}
      }
      state = state.copyWith(
        error: _mapMenuError(error, 'Failed to update the menu photo.'),
      );
      return false;
    }
  }

  Future<bool> removeMenuItemImage({
    required String itemId,
    String? storagePath,
  }) async {
    try {
      await menuService.setMenuItemImage(itemId: itemId);
      if (storagePath != null && storagePath.isNotEmpty) {
        try {
          await menuService.removeMenuImageObject(storagePath);
        } catch (_) {}
      }
      await fetchItems();
      state = state.copyWith(clearError: true);
      return true;
    } catch (error, _) {
      state = state.copyWith(
        error: _mapMenuError(error, 'Failed to remove the menu photo.'),
      );
      return false;
    }
  }

  Future<MenuImportResult?> importMenuItems(
    List<Map<String, dynamic>> rows,
  ) async {
    try {
      final result = await menuService.importMenuItems(
        storeId: storeId,
        rows: rows,
      );
      await fetchAll();
      state = state.copyWith(clearError: true);
      return result;
    } catch (error, _) {
      state = state.copyWith(
        error: _mapMenuError(error, 'Failed to import menus from Excel.'),
      );
      return null;
    }
  }
}

final menuProvider = StateNotifierProvider.autoDispose
    .family<MenuNotifier, MenuState, String>(
      (ref, storeId) => MenuNotifier(storeId),
    );
