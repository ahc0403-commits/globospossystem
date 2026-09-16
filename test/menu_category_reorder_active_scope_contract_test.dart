import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('category reorder matches the active category list shown by admin', () {
    final migration = File(
      'supabase/migrations/'
      '20260916120000_menu_category_reorder_active_scope.sql',
    ).readAsStringSync();

    expect(
      RegExp(r'AND is_active = true').allMatches(migration).length,
      greaterThanOrEqualTo(5),
    );
    expect(migration, contains('AND category.is_active = true'));
    expect(migration, contains("lower('메뉴 TOP7')"));
    expect(migration, contains('THEN 0'));
    expect(migration, contains('row_number() OVER'));
    expect(
      migration,
      contains(
        'CREATE OR REPLACE FUNCTION '
        'public.admin_reorder_menu_categories',
      ),
    );
  });
}
