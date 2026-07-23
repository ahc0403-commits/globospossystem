import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260723040000_photo_ops_manager_inventory_access.sql';

  test('Photo manager and operator receive store-scoped inventory access', () {
    final sql = File(migrationPath).readAsStringSync();

    expect(sql, contains("'photo_objet_master'"));
    expect(sql, contains("'photo_objet_store_operator'"));
    expect(sql, contains('public.user_accessible_stores(auth.uid())'));
    expect(sql, contains('REVOKE ALL ON FUNCTION'));
    expect(sql, contains('TO authenticated'));
  });

  test('production deploy gate verifies the targeted recovery migration', () {
    final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();
    final preflight = File(
      'scripts/preflight_photo_ops_manager_inventory_access.sql',
    ).readAsStringSync();
    final verify = File(
      'scripts/verify_photo_ops_manager_inventory_access.sql',
    ).readAsStringSync();

    expect(
      deploy,
      contains('20260723040000_photo_ops_manager_inventory_access.sql'),
    );
    expect(
      deploy,
      contains('preflight_photo_ops_manager_inventory_access.sql'),
    );
    expect(deploy, contains('verify_photo_ops_manager_inventory_access.sql'));
    expect(
      preflight,
      contains('PHOTO_OPS_INVENTORY_PREFLIGHT_FUNCTION_MISSING'),
    );
    expect(verify, contains('PHOTO_OPS_INVENTORY_ACCESS_VERIFICATION_FAILED'));
  });

  test(
    'Photo dashboard isolates section failures and loads scoped latest sales',
    () {
      final service = File(
        'lib/features/photo_ops/photo_ops_service.dart',
      ).readAsStringSync();

      expect(service, contains('attendanceWarningDetail'));
      expect(service, contains('inventoryWarningDetail'));
      expect(service, contains('payrollWarningDetail'));
      expect(service, contains("rpc('get_photo_ops_latest_sales')"));
    },
  );
}
