import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260918020000_admin_menu_item_archive.sql';

  test('menu deletion archives active state and preserves catalog identity', () {
    final migration = File(migrationPath).readAsStringSync();
    final archiveStart = migration.indexOf(
      'CREATE OR REPLACE FUNCTION public.admin_archive_menu_item',
    );
    final archiveEnd = migration.indexOf(
      'REVOKE ALL ON FUNCTION public.admin_archive_menu_item',
    );
    expect(archiveStart, greaterThanOrEqualTo(0));
    expect(archiveEnd, greaterThan(archiveStart));

    final archiveFunction = migration.substring(archiveStart, archiveEnd);
    expect(archiveFunction, contains('is_archived = true'));
    expect(archiveFunction, contains('is_available = false'));
    expect(archiveFunction, contains('is_visible_public = false'));
    expect(archiveFunction, contains('MENU_COMBO_COMPONENT_IN_USE'));
    expect(archiveFunction, contains("'delete_mode', 'archive'"));
    expect(archiveFunction, isNot(contains('DELETE FROM public.menu_items')));
    expect(
      migration,
      contains(
        "item.category_id = v_existing.id\n      AND item.is_archived = false",
      ),
    );
    expect(
      migration,
      contains('GRANT EXECUTE ON FUNCTION public.admin_archive_menu_item'),
    );
  });

  test('admin menu surface and provider expose the archive workflow', () {
    final service = File(
      'lib/core/services/menu_service.dart',
    ).readAsStringSync();
    final provider = File(
      'lib/features/admin/providers/menu_provider.dart',
    ).readAsStringSync();
    final menuTab = File(
      'lib/features/admin/tabs/menu_tab.dart',
    ).readAsStringSync();

    expect(service, contains("'admin_archive_menu_item'"));
    expect(provider, contains('Future<bool> archiveMenuItem'));
    expect(provider, contains('maxSortOrder + 1'));
    expect(menuTab, contains('admin_menu_delete_item_'));
    expect(menuTab, contains('admin_menu_delete_item_dialog'));
    expect(menuTab, contains('admin_menu_delete_item_confirm'));
    expect(menuTab, contains('menuDeleteItemConfirm'));
  });

  test('menu delete copy is localized in Korean Vietnamese and English', () {
    for (final locale in ['ko', 'vi', 'en']) {
      final arb = File('lib/l10n/app_$locale.arb').readAsStringSync();
      expect(arb, contains('"menuDeleteItem"'));
      expect(arb, contains('"menuDeleteItemTitle"'));
      expect(arb, contains('"menuDeleteItemConfirm"'));
      expect(arb, contains('"menuItemDeleted"'));
    }
  });
}
