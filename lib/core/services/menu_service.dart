import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';

class MenuImageUploadResult {
  const MenuImageUploadResult({
    required this.publicUrl,
    required this.storagePath,
  });

  final String publicUrl;
  final String storagePath;
}

class MenuImportResult {
  const MenuImportResult({
    required this.categoryCount,
    required this.itemCount,
    required this.preservedImageCount,
  });

  final int categoryCount;
  final int itemCount;
  final int preservedImageCount;

  factory MenuImportResult.fromJson(Map<String, dynamic> json) {
    int asInt(Object? value) => switch (value) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value) ?? 0,
      _ => 0,
    };

    return MenuImportResult(
      categoryCount: asInt(
        json['category_count'] ?? json['created_category_count'],
      ),
      itemCount: asInt(json['item_count'] ?? json['imported_item_count']),
      preservedImageCount: asInt(json['preserved_image_count']),
    );
  }
}

class MenuWorkbookUpdateResult {
  const MenuWorkbookUpdateResult({
    required this.updatedCategoryCount,
    required this.updatedItemCount,
    required this.preservedImageCount,
  });

  final int updatedCategoryCount;
  final int updatedItemCount;
  final int preservedImageCount;

  factory MenuWorkbookUpdateResult.fromJson(Map<String, dynamic> json) {
    int asInt(Object? value) => switch (value) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value) ?? 0,
      _ => 0,
    };

    return MenuWorkbookUpdateResult(
      updatedCategoryCount: asInt(json['updated_category_count']),
      updatedItemCount: asInt(json['updated_item_count']),
      preservedImageCount: asInt(json['preserved_image_count']),
    );
  }
}

class MenuService {
  Future<List<Map<String, dynamic>>> fetchCategories(String storeId) async {
    // postgrest-dart's order() defaults to DESCENDING; sort_order must be
    // ascending or the menu browser auto-selects the last (often empty test)
    // category and renders a blank menu.
    final response = await supabase
        .from('menu_categories')
        .select()
        .eq('restaurant_id', storeId)
        .eq('is_active', true)
        .order('sort_order', ascending: true);
    return response
        .map<Map<String, dynamic>>((c) => Map<String, dynamic>.from(c))
        .toList();
  }

  Future<List<Map<String, dynamic>>> fetchItems(String storeId) async {
    final response = await supabase
        .from('menu_items')
        .select(
          '*, '
          'menu_combo_components!'
          'menu_combo_components_combo_menu_item_id_fkey('
          'id, component_menu_item_id, quantity, sort_order, '
          'component:menu_items!'
          'menu_combo_components_component_menu_item_id_fkey('
          'id, name, name_ko, name_vi, name_en, is_available'
          '))',
        )
        .eq('restaurant_id', storeId)
        .eq('is_archived', false)
        .order('sort_order', ascending: true);
    return response
        .map<Map<String, dynamic>>((i) => Map<String, dynamic>.from(i))
        .toList();
  }

  Future<void> addCategory({
    required String storeId,
    required String nameKo,
    required String nameVi,
    required String nameEn,
    required int sortOrder,
  }) async {
    await supabase.rpc(
      'admin_create_menu_category_i18n',
      params: {
        'p_store_id': storeId,
        'p_name_ko': nameKo,
        'p_name_vi': nameVi,
        'p_name_en': nameEn,
        'p_sort_order': sortOrder,
      },
    );
  }

  Future<Map<String, dynamic>> addMenuItem({
    required String storeId,
    required String categoryId,
    required String nameKo,
    required String nameVi,
    required String nameEn,
    required double price,
    required int sortOrder,
  }) async {
    final response = await supabase.rpc(
      'admin_create_menu_item_i18n',
      params: {
        'p_store_id': storeId,
        'p_category_id': categoryId,
        'p_name_ko': nameKo,
        'p_name_vi': nameVi,
        'p_name_en': nameEn,
        'p_price': price,
        'p_sort_order': sortOrder,
        'p_is_available': true,
      },
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<void> updateCategory({
    required String categoryId,
    required String nameKo,
    required String nameVi,
    required String nameEn,
  }) async {
    await supabase.rpc(
      'admin_update_menu_category_i18n',
      params: {
        'p_category_id': categoryId,
        'p_name_ko': nameKo,
        'p_name_vi': nameVi,
        'p_name_en': nameEn,
      },
    );
  }

  Future<void> deleteCategory(String categoryId) async {
    await supabase.rpc(
      'admin_delete_menu_category',
      params: {'p_category_id': categoryId},
    );
  }

  Future<void> reorderCategories({
    required String storeId,
    required List<String> categoryIds,
  }) async {
    await supabase.rpc(
      'admin_reorder_menu_categories',
      params: {'p_store_id': storeId, 'p_category_ids': categoryIds},
    );
  }

  Future<void> setMenuCombo({
    required String itemId,
    required bool isCombo,
    required List<Map<String, dynamic>> components,
    int drinkChoiceCount = 0,
  }) async {
    await supabase.rpc(
      'admin_set_menu_combo',
      params: {
        'p_item_id': itemId,
        'p_is_combo': isCombo,
        'p_components': components,
        'p_drink_choice_count': drinkChoiceCount,
      },
    );
  }

  Future<void> toggleAvailability(String itemId, bool isAvailable) async {
    await supabase.rpc(
      'set_menu_item_availability',
      params: {'p_item_id': itemId, 'p_is_available': isAvailable},
    );
  }

  Future<void> togglePublicVisibility(
    String itemId,
    bool isVisiblePublic,
  ) async {
    await supabase.rpc(
      'admin_update_menu_item',
      params: {'p_item_id': itemId, 'p_is_visible_public': isVisiblePublic},
    );
  }

  Future<void> updateMenuItem({
    required String itemId,
    required String nameKo,
    required String nameVi,
    required String nameEn,
    required double price,
  }) async {
    await supabase.rpc(
      'admin_update_menu_item_i18n',
      params: {
        'p_item_id': itemId,
        'p_name_ko': nameKo,
        'p_name_vi': nameVi,
        'p_name_en': nameEn,
        'p_price': price,
      },
    );
  }

  Future<void> setMenuFulfillmentRoute({
    required String itemId,
    required bool floorDirect,
  }) async {
    await supabase.rpc(
      'admin_set_menu_fulfillment_route',
      params: {
        'p_item_id': itemId,
        'p_route': floorDirect ? 'floor_direct' : 'kitchen_tray_floor',
      },
    );
  }

  Future<void> deleteMenuItem(String itemId) async {
    await supabase.rpc('admin_delete_menu_item', params: {'p_item_id': itemId});
  }

  Future<MenuImageUploadResult> uploadMenuImage({
    required String storeId,
    required String itemId,
    required XFile file,
  }) async {
    final bytes = await file.readAsBytes();
    final compressed = _compressMenuImage(bytes);
    final objectId = DateTime.now().toUtc().microsecondsSinceEpoch;
    final path = '$storeId/$itemId/$objectId.jpg';
    final bucket = supabase.storage.from('menu-images');

    await bucket.uploadBinary(
      path,
      compressed,
      fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: false),
    );

    return MenuImageUploadResult(
      publicUrl: bucket.getPublicUrl(path),
      storagePath: path,
    );
  }

  Future<void> setMenuItemImage({
    required String itemId,
    String? imageUrl,
    String? storagePath,
  }) async {
    await supabase.rpc(
      'admin_set_menu_item_image',
      params: {
        'p_item_id': itemId,
        'p_image_url': imageUrl,
        'p_image_storage_path': storagePath,
      },
    );
  }

  Future<void> removeMenuImageObject(String storagePath) async {
    await supabase.storage.from('menu-images').remove([storagePath]);
  }

  Uint8List _compressMenuImage(Uint8List bytes) {
    final original = img.decodeImage(bytes);
    if (original == null) {
      throw StateError('MENU_IMAGE_INVALID');
    }

    final longestEdge = original.width >= original.height
        ? original.width
        : original.height;
    final resized = longestEdge > 1600
        ? img.copyResize(
            original,
            width: original.width >= original.height ? 1600 : null,
            height: original.height > original.width ? 1600 : null,
          )
        : original;

    return Uint8List.fromList(img.encodeJpg(resized, quality: 82));
  }

  Future<MenuImportResult> importMenuItems({
    required String storeId,
    required List<Map<String, dynamic>> rows,
  }) async {
    final response = await supabase.rpc(
      'admin_import_menu_items',
      params: {'p_store_id': storeId, 'p_rows': rows},
    );

    return MenuImportResult.fromJson(
      Map<String, dynamic>.from(response as Map),
    );
  }

  Future<MenuWorkbookUpdateResult> updateMenuWorkbook({
    required String storeId,
    required List<Map<String, dynamic>> categories,
    required List<Map<String, dynamic>> items,
  }) async {
    final response = await supabase.rpc(
      'admin_update_menu_workbook_i18n',
      params: {
        'p_store_id': storeId,
        'p_categories': categories,
        'p_items': items,
      },
    );

    return MenuWorkbookUpdateResult.fromJson(
      Map<String, dynamic>.from(response as Map),
    );
  }
}

final menuService = MenuService();
