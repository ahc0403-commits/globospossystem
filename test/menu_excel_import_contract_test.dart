import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('bulk menu import RPC is authorized, atomic, bounded, and audited', () {
    final sql = File(
      'supabase/migrations/20260721020000_admin_menu_excel_import.sql',
    ).readAsStringSync();

    expect(sql, contains('admin_import_menu_items'));
    expect(sql, contains('require_admin_actor_for_restaurant(p_store_id)'));
    expect(sql, contains("jsonb_typeof(p_rows) <> 'array'"));
    expect(sql, contains('jsonb_array_length(p_rows) > 500'));
    expect(sql, contains('MENU_IMPORT_DUPLICATE_ROWS'));
    expect(sql, contains('MENU_IMPORT_ITEM_EXISTS'));
    expect(sql, contains("'source', 'excel_import'"));
    expect(sql, contains('SECURITY DEFINER'));
    expect(
      sql,
      contains(
        'GRANT EXECUTE ON FUNCTION public.admin_import_menu_items(UUID, JSONB) TO authenticated',
      ),
    );
  });

  test('menu screen exposes Excel selection, preview, and atomic import', () {
    final source = File(
      'lib/features/admin/tabs/menu_tab.dart',
    ).readAsStringSync();

    expect(source, contains("package:file_selector/file_selector.dart"));
    expect(source, contains("package:desktop_drop/desktop_drop.dart"));
    expect(source, contains("extensions: <String>['xlsx']"));
    expect(source, contains('admin_menu_import_drop_zone'));
    expect(source, contains('onDragDone'));
    expect(source, contains('parseMenuImportWorkbook'));
    expect(source, contains('admin_menu_import_preview_dialog'));
    expect(source, contains('menuNotifier.importMenuItems'));
  });

  test('replacement import retains photos and safely archives absent rows', () {
    final sql = File(
      'supabase/migrations/20260805140000_admin_menu_excel_replace.sql',
    ).readAsStringSync();

    expect(sql, contains('pg_advisory_xact_lock'));
    expect(sql, contains('matched_item_id'));
    expect(sql, contains('UPDATE public.menu_items mi'));
    expect(sql, isNot(contains('SET image_url =')));
    expect(sql, isNot(contains('image_storage_path =')));
    expect(sql, contains('UPDATE public.menu_items mi'));
    expect(sql, contains('SET is_archived = true'));
    expect(sql, contains('SET is_archived = false'));
    expect(sql, contains("'admin_replace_menu_catalog'"));
    expect(sql, contains("'preserved_image_count'"));
    expect(sql, contains('SECURITY DEFINER'));

    final deployment = File(
      'scripts/deploy_pos_production.sh',
    ).readAsStringSync();
    expect(
      deployment,
      contains(r'apply_migration_by_convention "$MIGRATION_FILE"'),
    );
    expect(
      File('scripts/preflight_admin_menu_excel_replace.sql').existsSync(),
      isTrue,
    );
    expect(
      File('scripts/verify_admin_menu_excel_replace.sql').existsSync(),
      isTrue,
    );
  });
}
