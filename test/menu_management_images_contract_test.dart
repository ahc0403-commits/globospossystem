import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('menu image migration keeps storage and metadata store-scoped', () {
    final migration = File(
      'supabase/migrations/20260722010000_menu_category_management_and_images.sql',
    ).readAsStringSync();

    expect(migration, contains('ADD COLUMN IF NOT EXISTS image_url text'));
    expect(migration, contains("'menu-images'"));
    expect(migration, contains('file_size_limit'));
    expect(migration, contains('storage.foldername(name))[1]'));
    expect(migration, contains('public.user_accessible_stores(auth.uid())'));
    expect(migration, contains('admin_set_menu_item_image'));
    expect(migration, contains('MENU_IMAGE_PATH_INVALID'));
    expect(migration, contains('MENU_IMAGE_OBJECT_NOT_FOUND'));
    expect(migration, contains('MENU_CATEGORY_NOT_EMPTY'));
    expect(migration, contains("'image_url', mi.image_url"));
  });

  test('admin menu surface exposes category and photo controls', () {
    final service = File(
      'lib/core/services/menu_service.dart',
    ).readAsStringSync();
    final provider = File(
      'lib/features/admin/providers/menu_provider.dart',
    ).readAsStringSync();
    final menuTab = File(
      'lib/features/admin/tabs/menu_tab.dart',
    ).readAsStringSync();
    final qrModel = File(
      'lib/core/services/qr_order_service.dart',
    ).readAsStringSync();

    expect(service, contains("from('menu-images')"));
    expect(service, contains('getPublicUrl(path)'));
    expect(service, contains('img.encodeJpg'));
    expect(provider, contains('updateCategory'));
    expect(provider, contains('deleteCategory'));
    expect(provider, contains('replaceMenuItemImage'));
    expect(menuTab, contains('admin_menu_edit_category_'));
    expect(menuTab, contains('admin_menu_delete_category_'));
    expect(menuTab, contains('admin_menu_photo_picker'));
    expect(menuTab, contains('admin_menu_choose_photo'));
    expect(qrModel, contains("json['image_url']"));
  });
}
