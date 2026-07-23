import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void expectInOrder(String source, List<String> markers) {
  var cursor = -1;
  for (final marker in markers) {
    final index = source.indexOf(marker, cursor + 1);
    expect(index, isNonNegative, reason: 'Missing marker: $marker');
    expect(index, greaterThan(cursor), reason: 'Marker out of order: $marker');
    cursor = index;
  }
}

void main() {
  test('cashier exposes attendance kiosk entry for tablet web use', () {
    final source = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();
    final platformInfo = File(
      'lib/core/layout/platform_info.dart',
    ).readAsStringSync();

    expect(source, contains("context.go('/attendance-kiosk')"));
    expect(source, contains("Key('cashier_attendance_kiosk_entry')"));
    expect(source, contains("Key('cashier_compact_attendance_kiosk_entry')"));
    expect(source, contains('label: Text(l10n.attendance)'));
    expect(source, contains('minimumSize: const Size(112, 48)'));
    expect(platformInfo, contains('isAndroid || isWeb'));
  });

  test('authenticated routed screens expose shared nav and root keys', () {
    final surfaces = <String, List<String>>{
      'lib/features/waiter/waiter_screen.dart': [
        'AppNavBar(',
        "Key('dashboard_root')",
      ],
      'lib/features/kitchen/kitchen_screen.dart': [
        'AppNavBar(',
        "Key('kitchen_root')",
      ],
      'lib/features/cashier/cashier_screen.dart': [
        'AppNavBar(',
        "Key('cashier_root')",
      ],
      'lib/features/admin/admin_screen.dart': [
        'AppNavBar(',
        "Key('admin_root')",
      ],
      'lib/features/super_admin/super_admin_screen.dart': [
        'AppNavBar(',
        "Key('admin_root')",
      ],
      'lib/features/photo_ops/photo_ops_screen.dart': [
        'AppNavBar(',
        "Key('photo_ops_root')",
      ],
      'lib/features/payment/payment_detail_screen.dart': [
        'const AppNavBar()',
        "Key('payment_detail_root')",
      ],
      'lib/features/qc/qc_check_screen.dart': [
        'AppNavBar()',
        "Key('qc_check_root')",
      ],
      'lib/features/qc/qc_review_screen.dart': [
        'AppNavBar()',
        "Key('qc_review_root')",
      ],
      'lib/features/attendance/attendance_kiosk_screen.dart': [
        'const AppNavBar()',
        "Key('attendance_kiosk_root')",
      ],
    };

    for (final entry in surfaces.entries) {
      final source = readRepoFile(entry.key);
      for (final marker in entry.value) {
        expect(source, contains(marker), reason: '${entry.key}: $marker');
      }
    }
  });

  test('shared authenticated navigation exposes a working logout control', () {
    final nav = readRepoFile('lib/widgets/app_nav_bar.dart');

    expect(nav, contains('this.showLogout = true'));
    expect(nav, contains("Key('app_nav_logout_button')"));
    expect(nav, contains('tooltip: l10n.logout'));
    expect(nav, contains('authProvider.notifier).logout()'));
    expect(nav, contains('final logoutOnly = showLogout && veryCompact'));
  });

  test('admin nav order stays aligned with tab body order and roots', () {
    final admin = readRepoFile('lib/features/admin/admin_screen.dart');
    final tables = readRepoFile('lib/features/admin/tabs/tables_tab.dart');
    final menu = readRepoFile('lib/features/admin/tabs/menu_tab.dart');
    final inventory = readRepoFile(
      'lib/features/inventory_purchase/inventory_purchase_screen.dart',
    );
    final delivery = readRepoFile(
      'lib/features/delivery/screens/delivery_settlement_tab.dart',
    );

    expectInOrder(admin, const [
      "Key('nav_tables')",
      "Key('nav_menu')",
      "Key('nav_staff')",
      "Key('nav_reports')",
      "Key('nav_attendance')",
      "Key('nav_inventory')",
      "Key('nav_qc')",
      "Key('nav_settings')",
      "Key('nav_delivery_settlement')",
      "Key('nav_einvoice')",
    ]);
    expectInOrder(admin, const [
      'const TablesTab()',
      'const MenuTab()',
      'const StaffTab()',
      'ReportsTab(overrideStoreId: widget.overrideRestaurantId)',
      'const AttendanceTab()',
      'const InventoryPurchaseScreen()',
      'const QcTab()',
      'const SettingsTab()',
      'tabs.add(const DeliverySettlementTab())',
      'tabs.add(const EinvoiceTab())',
    ]);
    expect(tables, contains("Key('admin_tables_root')"));
    expect(menu, contains("Key('admin_menu_root')"));
    expect(inventory, contains("Key('inventory_root')"));
    expect(delivery, contains("Key('delivery_settlement_root')"));
  });

  test('payment detail route is guarded by the shared role route contract', () {
    final router = readRepoFile('lib/core/router/app_router.dart');
    final roleRoutes = readRepoFile('lib/core/utils/role_routes.dart');

    expect(router, contains("path: '/payments/:paymentId'"));
    expect(router, contains("path.startsWith('/payments/')"));
    expect(router, contains('canAccessRouteForRole('));
    expect(roleRoutes, contains("path.startsWith('/payments/')"));
  });

  test(
    'button activation smoke data stays capped at three inputs per button',
    () {
      final smoke = readRepoFile(
        'integration_test/full_multi_account_smoke_test.dart',
      );

      expect(
        smoke,
        contains('const _maxTestDataInputsPerActivatableButton = 3;'),
      );
      expect(
        smoke,
        contains('maxPasses <= _maxTestDataInputsPerActivatableButton'),
      );
    },
  );
}
