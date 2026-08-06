import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migrationPath =
      'supabase/migrations/20260806122400_menu_sold_out_cashier_access.sql';

  test('sold-out mutation is narrow, store-scoped, and audited', () {
    final sql = readRepoFile(migrationPath);

    expect(
      sql,
      contains('CREATE OR REPLACE FUNCTION public.set_menu_item_availability'),
    );
    expect(
      sql,
      contains(
        "'cashier', 'admin', 'store_admin', 'brand_admin', 'super_admin'",
      ),
    );
    expect(sql, contains('public.user_accessible_stores(auth.uid())'));
    expect(sql, contains('SET is_available = p_is_available'));
    expect(sql, contains("'set_menu_item_availability'"));
    expect(sql, contains('REVOKE ALL ON FUNCTION'));
    expect(sql, isNot(contains('is_visible_public =')));
    expect(sql, isNot(contains('price =')));
  });

  test('sold-out migration version is unique in the repository', () {
    final version = File(migrationPath).uri.pathSegments.last.split('_').first;
    final matchingMigrations = Directory('supabase/migrations')
        .listSync()
        .whereType<File>()
        .where((file) => file.uri.pathSegments.last.startsWith('${version}_'))
        .toList();

    expect(matchingMigrations, hasLength(1));
  });

  test(
    'sold-out DB change and app deploy share one production release gate',
    () {
      const preflightPath =
          'scripts/preflight_menu_sold_out_cashier_access.sql';
      const verifyPath = 'scripts/verify_menu_sold_out_cashier_access.sql';
      final preflight = readRepoFile(preflightPath);
      final verify = readRepoFile(verifyPath);
      final deploy = readRepoFile('scripts/deploy_pos_production.sh');
      final combinedRelease = readRepoFile(
        'scripts/release_menu_sold_out_cashier_access.sh',
      );

      expect(File(preflightPath).existsSync(), isTrue);
      expect(File(verifyPath).existsSync(), isTrue);
      expect(preflight, contains('public.user_accessible_stores(uuid)'));
      expect(verify, contains('set_menu_item_availability(uuid,boolean)'));
      expect(verify, contains("has_function_privilege('anon'"));

      final releaseFlow = deploy.substring(deploy.indexOf('main() {'));
      final migrationGate = releaseFlow.indexOf('apply_migration');
      final appDeploy = releaseFlow.indexOf('deploy_vercel', migrationGate);
      expect(migrationGate, greaterThanOrEqualTo(0));
      expect(appDeploy, greaterThan(migrationGate));
      expect(
        deploy,
        contains('apply_migration_by_convention "\$MIGRATION_FILE"'),
      );
      expect(combinedRelease, contains('deploy_pos_production.sh'));
      expect(combinedRelease, contains('--migration'));
      expect(combinedRelease, contains(migrationPath));
      expect(combinedRelease, contains('--skip-db|--skip-vercel|--db-only'));
    },
  );

  test('store manager and cashier surfaces use the sold-out contract', () {
    final service = readRepoFile('lib/core/services/menu_service.dart');
    final adminMenu = readRepoFile('lib/features/admin/tabs/menu_tab.dart');
    final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');
    final dialog = readRepoFile(
      'lib/features/cashier/cashier_sold_out_dialog.dart',
    );

    expect(service, contains("'set_menu_item_availability'"));
    expect(adminMenu, contains('menuNotifier.toggleAvailability'));
    expect(cashier, contains("Key('cashier_sold_out_menu_action')"));
    expect(dialog, contains("Key('cashier_sold_out_dialog')"));
    expect(dialog, contains("'cashier_menu_availability_\$itemId'"));
  });

  test(
    'checkout already supports order discount and service-item exclusion',
    () {
      final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');
      final discount = readRepoFile('lib/features/cashier/discount_modal.dart');
      final serviceSql = readRepoFile(
        'supabase/migrations/20260707010000_service_item_exclusion_v1.sql',
      );

      expect(cashier, contains("Key('cashier_discount_dialog')"));
      expect(discount, contains('applyOrderDiscount'));
      expect(discount, contains("_mode == 'percent'"));
      expect(cashier, contains("Key('cashier_service_item_dialog')"));
      expect(cashier, contains('markOrderItemService'));
      expect(serviceSql, contains('SET is_service_item = true'));
      expect(
        serviceSql,
        contains('COALESCE(oi.is_service_item, false) = false'),
      );
    },
  );
}
