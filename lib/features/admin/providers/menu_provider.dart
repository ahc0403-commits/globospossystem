import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../main.dart';

class MenuState {
  const MenuState({
    this.categories = const AsyncValue.loading(),
    this.items = const AsyncValue.loading(),
    this.selectedCategoryId,
  });

  final AsyncValue<List<Map<String, dynamic>>> categories;
  final AsyncValue<List<Map<String, dynamic>>> items;
  final String? selectedCategoryId;

  MenuState copyWith({
    AsyncValue<List<Map<String, dynamic>>>? categories,
    AsyncValue<List<Map<String, dynamic>>>? items,
    String? selectedCategoryId,
    bool clearSelectedCategory = false,
  }) {
    return MenuState(
      categories: categories ?? this.categories,
      items: items ?? this.items,
      selectedCategoryId: clearSelectedCategory
          ? null
          : (selectedCategoryId ?? this.selectedCategoryId),
    );
  }
}

class MenuNotifier extends StateNotifier<MenuState> {
  MenuNotifier(this.restaurantId) : super(const MenuState()) {
    fetchAll();
  }

  final String restaurantId;

  Future<void> fetchAll() async {
    await Future.wait([fetchCategories(), fetchItems()]);
  }

  Future<void> fetchCategories() async {
    state = state.copyWith(categories: const AsyncValue.loading());
    try {
      final response = await supabase
          .from('menu_categories')
          .select()
          .eq('restaurant_id', restaurantId)
          .order('sort_order');

      final categories = response
          .map<Map<String, dynamic>>((category) => Map<String, dynamic>.from(category))
          .toList();

      final selectedId = state.selectedCategoryId;
      final hasSelectedId = selectedId != null &&
          categories.any((category) => category['id'].toString() == selectedId);

      state = state.copyWith(
        categories: AsyncValue.data(categories),
        selectedCategoryId: categories.isNotEmpty
            ? (hasSelectedId ? selectedId : categories.first['id'].toString())
            : null,
        clearSelectedCategory: categories.isEmpty,
      );
    } catch (error, stackTrace) {
      state = state.copyWith(categories: AsyncValue.error(error, stackTrace));
    }
  }

  Future<void> fetchItems() async {
    state = state.copyWith(items: const AsyncValue.loading());
    try {
      final response = await supabase
          .from('menu_items')
          .select()
          .eq('restaurant_id', restaurantId)
          .order('sort_order');

      final items = response
          .map<Map<String, dynamic>>((item) => Map<String, dynamic>.from(item))
          .toList();

      state = state.copyWith(items: AsyncValue.data(items));
    } catch (error, stackTrace) {
      state = state.copyWith(items: AsyncValue.error(error, stackTrace));
    }
  }

  void selectCategory(String categoryId) {
    state = state.copyWith(selectedCategoryId: categoryId);
  }

  Future<void> addCategory(String name) async {
    try {
      final currentCategories = state.categories.valueOrNull ?? [];
      await supabase.from('menu_categories').insert({
        'restaurant_id': restaurantId,
        'name': name,
        'sort_order': currentCategories.length,
      });
      await fetchCategories();
    } catch (error, stackTrace) {
      state = state.copyWith(categories: AsyncValue.error(error, stackTrace));
    }
  }

  Future<void> addMenuItem(String categoryId, String name, double price) async {
    try {
      final currentItems = state.items.valueOrNull ?? [];
      final sortOrder = currentItems
          .where((item) => item['category_id'].toString() == categoryId)
          .length;

      await supabase.from('menu_items').insert({
        'restaurant_id': restaurantId,
        'category_id': categoryId,
        'name': name,
        'price': price,
        'is_available': true,
        'sort_order': sortOrder,
      });
      await fetchItems();
    } catch (error, stackTrace) {
      state = state.copyWith(items: AsyncValue.error(error, stackTrace));
    }
  }

  Future<void> toggleAvailability(String itemId, bool isAvailable) async {
    try {
      await supabase
          .from('menu_items')
          .update({'is_available': isAvailable})
          .eq('id', itemId);
      await fetchItems();
    } catch (error, stackTrace) {
      state = state.copyWith(items: AsyncValue.error(error, stackTrace));
    }
  }

  Future<void> updateMenuItem({
    required String itemId,
    required String name,
    required double price,
  }) async {
    try {
      await supabase
          .from('menu_items')
          .update({'name': name, 'price': price})
          .eq('id', itemId);
      await fetchItems();
    } catch (error, stackTrace) {
      state = state.copyWith(items: AsyncValue.error(error, stackTrace));
    }
  }
}

final menuProvider = StateNotifierProvider.autoDispose
    .family<MenuNotifier, MenuState, String>(
      (ref, restaurantId) => MenuNotifier(restaurantId),
    );
