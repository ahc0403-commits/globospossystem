import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('QR menu mirrors active admin categories and defaults new menus public', () {
    final migration = File(
      'supabase/migrations/20260916130000_qr_menu_category_auto_sync.sql',
    ).readAsStringSync();
    final screen = File(
      'lib/features/qr_order/qr_order_screen.dart',
    ).readAsStringSync();

    expect(migration, contains("lower('메뉴 TOP7')"));
    expect(migration, contains('SET is_visible_public = true'));
    expect(
      migration,
      contains(
        'COALESCE(p_is_available, true), true, COALESCE(p_sort_order, 0)',
      ),
    );
    expect(
      migration,
      contains('AND category.is_active = true;'),
    );
    expect(
      migration,
      isNot(contains('category.is_active = true\n    AND EXISTS')),
    );
    expect(migration, contains('AND menu.is_archived = false'));

    expect(
      screen,
      contains('Timer.periodic(const Duration(seconds: 15)'),
    );
    expect(screen, contains("event.affects({'menu', 'tables', 'settings'})"));
  });

  test('production gate verifies TOP7 and function privileges', () {
    final preflight = File(
      'scripts/preflight_qr_menu_category_auto_sync.sql',
    ).readAsStringSync();
    final verify = File(
      'scripts/verify_qr_menu_category_auto_sync.sql',
    ).readAsStringSync();

    expect(preflight, contains('QR_MENU_CATEGORY_AUTO_SYNC_DEPENDENCY_MISSING'));
    expect(preflight, contains("'anon'"));
    expect(verify, contains('QR_MENU_TOP7_BACKFILL_INCOMPLETE'));
    expect(verify, contains('QR_MENU_CREATE_DEFAULT_VISIBILITY_INVALID'));
    expect(verify, contains('QR_MENU_FUNCTION_PRIVILEGE_INVALID'));
  });
}
