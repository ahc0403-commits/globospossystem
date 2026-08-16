import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('paperless Vietnamese name is additive, admin-only, and KDS-only', () {
    final migration = File(
      'supabase/migrations/'
      '20260815180000_paperless_menu_name_and_voice.sql',
    ).readAsStringSync();
    final service = File(
      'lib/core/services/menu_service.dart',
    ).readAsStringSync();
    final menuUi = File(
      'lib/features/admin/tabs/menu_tab.dart',
    ).readAsStringSync();
    final kds = File(
      'lib/features/emergency_fulfillment/emergency_fulfillment_screen.dart',
    ).readAsStringSync();

    expect(migration, contains('ADD COLUMN IF NOT EXISTS paperless_name_vi'));
    expect(migration, contains('menu_items_paperless_name_vi_valid'));
    expect(migration, contains('require_admin_actor_for_restaurant'));
    expect(migration, contains('admin_create_menu_item_i18n_paperless'));
    expect(migration, contains('admin_update_menu_item_i18n_paperless'));
    expect(migration, contains('admin_update_menu_workbook_i18n_catalog'));
    expect(migration, contains("v_entry ? 'paperless_name_vi'"));
    expect(migration, contains('emergency_localize_paperless_orders'));
    expect(migration, contains('get_emergency_station_snapshot_base'));
    expect(migration, contains('get_emergency_station_today_completed_base'));
    expect(migration, contains('FROM PUBLIC, anon, authenticated'));
    expect(service, contains("'p_paperless_name_vi': paperlessNameVi"));
    expect(menuUi, contains("Key('admin_menu_item_paperless_name_vi')"));
    expect(menuUi, contains("Key('admin_menu_edit_item_paperless_name_vi')"));
    expect(kds, contains('item.paperlessName'));
    expect(kds, contains('displayItem.paperlessName'));
  });

  test('Bunsik seed exactly contains the 71 spreadsheet menu mappings', () {
    final migration = File(
      'supabase/migrations/'
      '20260815181000_bunsik_paperless_menu_names.sql',
    ).readAsStringSync();
    final valuePattern = RegExp(
      r"^\s*\('(?:''|[^'])*', '(?:''|[^'])*'\)[,;]$",
      multiLine: true,
    );

    final seedValues = migration.substring(
      migration.indexOf(
        'INSERT INTO paperless_menu_seed(name_ko, paperless_name_vi) VALUES',
      ),
      migration.indexOf(r'DO $$'),
    );

    expect(valuePattern.allMatches(seedValues), hasLength(71));
    expect(migration, contains("('오리지널 김밥', 'Kimbap Truyền Thống')"));
    expect(migration, contains("('물티슈', 'Khăn Ướt')"));
    expect(
      migration,
      contains('SET paperless_name_vi = matched.paperless_name_vi'),
    );
    expect(migration, isNot(contains('SET name_vi = seed.paperless_name_vi')));
    expect(migration, contains("IN ('BT', 'SP')"));
    expect(
      migration,
      contains('BUNSIK_PAPERLESS_TARGET_STORE_CARDINALITY_INVALID'),
    );
    expect(migration, contains('BUNSIK_PAPERLESS_PER_STORE_COVERAGE_FAILED'));
    expect(migration, contains("('치즈떡붂이', '치즈떡볶이')"));
    expect(migration, contains('BUNSIK_PAPERLESS_SEED_VERIFICATION_FAILED'));
  });
}
