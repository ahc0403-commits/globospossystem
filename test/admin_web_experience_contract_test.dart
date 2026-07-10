import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('store owner web opens on a today-first operational overview', () {
    final admin = readRepoFile('lib/features/admin/admin_screen.dart');
    final overview = readRepoFile(
      'lib/features/admin/tabs/owner_overview_tab.dart',
    );
    final router = readRepoFile('lib/core/router/app_router.dart');

    expect(admin, contains('OwnerOverviewTab('));
    expect(admin, contains("Key('nav_overview')"));
    expect(overview, contains('adminTodaySummaryProvider(storeId)'));
    expect(overview, contains("Key('owner_overview_refresh')"));
    expect(overview, contains("Key('owner_overview_reports')"));
    expect(overview, contains("Key('owner_overview_inventory')"));
    expect(overview, contains('if (storeId == null)'));
    expect(router, contains("'overview' => 0"));
    expect(router, contains("'tables' => 1"));
  });

  test('system admin web prioritizes fleet health and store search', () {
    final screen = readRepoFile(
      'lib/features/super_admin/super_admin_screen.dart',
    );

    expect(screen, contains('state.activeRestaurantCount'));
    expect(screen, contains("Key('super_admin_store_search')"));
    expect(screen, contains('visibleRestaurants'));
    expect(screen, contains('superAdminStoreSearchHint'));
    expect(
      screen,
      isNot(contains("value: '\${safeIndex + 1}/\${items.length}'")),
    );
  });
}
