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
    required this.createdCategoryCount,
    required this.importedItemCount,
  });

  final int createdCategoryCount;
  final int importedItemCount;

  factory MenuImportResult.fromJson(Map<String, dynamic> json) {
    int asInt(Object? value) => switch (value) {
      int value => value,
      num value => value.toInt(),
      String value => int.tryParse(value) ?? 0,
      _ => 0,
    };

    return MenuImportResult(
      createdCategoryCount: asInt(json['created_category_count']),
      importedItemCount: asInt(json['imported_item_count']),
    );
  }
}

class MenuService {
  bool _isRpcSignatureMismatch(Object error, String functionName) {
    final message = error.toString().toLowerCase();
    if (!message.contains(functionName.toLowerCase())) {
      return false;
    }

    return message.contains('could not find the function') ||
        message.contains('function public.') ||
        message.contains('does not exist') ||
        message.contains('no function matches');
  }

  Future<List<Map<String, dynamic>>> fetchCategories(String storeId) async {
    // postgrest-dart's order() defaults to DESCENDING; sort_order must be
    // ascending or the menu browser auto-selects the last (often empty test)
    // category and renders a blank menu.
    final response = await supabase
        .from('menu_categories')
        .select()
        .eq('restaurant_id', storeId)
        .order('sort_order', ascending: true);
    return response
        .map<Map<String, dynamic>>((c) => Map<String, dynamic>.from(c))
        .toList();
  }

  Future<List<Map<String, dynamic>>> fetchItems(String storeId) async {
    final response = await supabase
        .from('menu_items')
        .select()
        .eq('restaurant_id', storeId)
        .order('sort_order', ascending: true);
    return response
        .map<Map<String, dynamic>>((i) => Map<String, dynamic>.from(i))
        .toList();
  }

  Future<void> addCategory({
    required String storeId,
    required String name,
    required int sortOrder,
  }) async {
    try {
      await supabase.rpc(
        'admin_create_menu_category',
        params: {
          'p_store_id': storeId,
          'p_name': name,
          'p_sort_order': sortOrder,
        },
      );
    } catch (error) {
      if (!_isRpcSignatureMismatch(error, 'admin_create_menu_category')) {
        rethrow;
      }

      await supabase.rpc(
        'admin_create_menu_category',
        params: {
          'p_restaurant_id': storeId,
          'p_name': name,
          'p_sort_order': sortOrder,
        },
      );
    }
  }

  Future<Map<String, dynamic>> addMenuItem({
    required String storeId,
    required String categoryId,
    required String name,
    required double price,
    required int sortOrder,
  }) async {
    final itemParams = {
      'p_category_id': categoryId,
      'p_name': name,
      'p_price': price,
      'p_sort_order': sortOrder,
      'p_is_available': true,
    };

    try {
      final response = await supabase.rpc(
        'admin_create_menu_item',
        params: {'p_store_id': storeId, ...itemParams},
      );
      return Map<String, dynamic>.from(response as Map);
    } catch (error) {
      if (!_isRpcSignatureMismatch(error, 'admin_create_menu_item')) {
        rethrow;
      }

      final response = await supabase.rpc(
        'admin_create_menu_item',
        params: {'p_restaurant_id': storeId, ...itemParams},
      );
      return Map<String, dynamic>.from(response as Map);
    }
  }

  Future<void> updateCategory({
    required String categoryId,
    required String name,
  }) async {
    await supabase.rpc(
      'admin_update_menu_category',
      params: {'p_category_id': categoryId, 'p_name': name},
    );
  }

  Future<void> deleteCategory(String categoryId) async {
    await supabase.rpc(
      'admin_delete_menu_category',
      params: {'p_category_id': categoryId},
    );
  }

  Future<void> toggleAvailability(String itemId, bool isAvailable) async {
    await supabase.rpc(
      'admin_update_menu_item',
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
    required String name,
    required double price,
  }) async {
    await supabase.rpc(
      'admin_update_menu_item',
      params: {'p_item_id': itemId, 'p_name': name, 'p_price': price},
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
}

final menuService = MenuService();
