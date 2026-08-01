import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationName = '20260801055557_restaurant_wet_tissue_charge.sql';

  test('wet-tissue charge migration has explicit production gates', () {
    final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();
    final preflight = File(
      'scripts/preflight_restaurant_wet_tissue_charge.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_restaurant_wet_tissue_charge.sql',
    ).readAsStringSync();

    expect(deploy, contains(migrationName));
    expect(
      deploy,
      contains('scripts/preflight_restaurant_wet_tissue_charge.sql'),
    );
    expect(deploy, contains('scripts/verify_restaurant_wet_tissue_charge.sql'));
    expect(
      preflight,
      contains('RESTAURANT_WET_TISSUE_BASE_CONSTRAINT_MISSING'),
    );
    expect(
      verification,
      contains('restaurant wet-tissue charge verification passed'),
    );
    expect(verification, contains("has_function_privilege('anon'"));
    expect(
      verification,
      contains('order_items_one_wet_tissue_charge_per_order_idx'),
    );
  });
}
