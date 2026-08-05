import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/production_gate_test_support.dart';

void main() {
  test('menu replacement is atomic, photo-preserving, and history-safe', () {
    final migration = File(
      'supabase/migrations/20260805140000_admin_menu_excel_replace.sql',
    ).readAsStringSync();

    expect(migration, contains('pg_advisory_xact_lock'));
    expect(migration, contains('matched_item_id'));
    expect(migration, contains('preserved_image_count'));
    expect(migration, contains('is_archived = true'));
    expect(migration, contains('is_available = false'));
    expect(migration, contains('is_visible_public = false'));
    expect(migration, isNot(contains('DELETE FROM public.menu_items')));
    expect(migration, contains('admin_update_menu_workbook_i18n_apply'));
    expect(migration, contains("'admin_replace_menu_catalog'"));
    expect(migration, contains('SECURITY DEFINER'));

    final deploy = readProductionGateContract();
    expect(deploy, contains('apply_migration_by_convention'));
    expect(
      File('scripts/preflight_admin_menu_excel_replace.sql').existsSync(),
      isTrue,
    );
    expect(
      File('scripts/verify_admin_menu_excel_replace.sql').existsSync(),
      isTrue,
    );
  });

  test('menu UI supports xlsx drag-and-drop and hides archived rows', () {
    final screen = File(
      'lib/features/admin/tabs/menu_tab.dart',
    ).readAsStringSync();
    final service = File(
      'lib/core/services/menu_service.dart',
    ).readAsStringSync();

    expect(screen, contains("package:desktop_drop/desktop_drop.dart"));
    expect(screen, contains('admin_menu_import_drop_zone'));
    expect(screen, contains('onDragDone'));
    expect(screen, contains("endsWith('.xlsx')"));
    expect(service, contains(".eq('is_archived', false)"));
    expect(service, contains(".eq('is_active', true)"));
  });
}
