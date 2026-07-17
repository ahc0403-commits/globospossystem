import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('migration and production scripts fail closed and remain additive', () {
    final migration = File(
      'supabase/migrations/20260717090000_store_opening_setup_wizard.sql',
    ).readAsStringSync();
    final preflight = File(
      'scripts/preflight_store_opening_setup_wizard.sql',
    ).readAsStringSync();
    final verify = File(
      'scripts/verify_store_opening_setup_wizard.sql',
    ).readAsStringSync();
    final rollback = File(
      'scripts/rollback_store_opening_setup_wizard.sql',
    ).readAsStringSync();
    final apply = File(
      'scripts/apply_store_opening_setup_wizard.sql',
    ).readAsStringSync();
    final productionDeploy = File(
      'scripts/deploy_pos_production.sh',
    ).readAsStringSync();

    expect(migration, contains('STORE_SETUP_DUPLICATE_ACTIVE_ROUTE_PREFLIGHT'));
    expect(migration, contains('printer_destinations_active_route_unique'));
    expect(migration, contains('admin_validate_store_opening_config'));
    expect(migration, contains('admin_apply_store_opening_config'));
    expect(migration, contains('admin_get_store_opening_readiness'));
    expect(migration, contains('FOR UPDATE'));
    expect(migration, contains("'admin_apply_store_opening_config'"));
    expect(migration, contains('REVOKE ALL ON FUNCTION'));
    expect(migration, isNot(contains('DELETE FROM public.tables')));
    expect(migration, isNot(contains('SET is_active = false')));
    expect(preflight, contains('STORE_SETUP_PREFLIGHT_OK'));
    expect(verify, contains('STORE_SETUP_VERIFY_OK'));
    expect(rollback, contains('STORE_SETUP_ROLLBACK_OK'));
    expect(apply, contains('20260717090000_store_opening_setup_wizard.sql'));
    expect(
      productionDeploy,
      contains('20260717090000_store_opening_setup_wizard.sql'),
    );
    expect(
      productionDeploy,
      contains('preflight_store_opening_setup_wizard.sql'),
    );
    expect(
      productionDeploy,
      contains('apply_store_opening_setup_wizard.sql'),
    );
    expect(
      productionDeploy,
      contains('verify_store_opening_setup_wizard.sql'),
    );
    expect(
      productionDeploy,
      contains('rollback_store_opening_setup_wizard.sql'),
    );
    expect(productionDeploy, contains('Rollback ready (not executed):'));
  });

  test('executable SQL contract covers security and failure invariants', () {
    final contract = File(
      'supabase/tests/store_opening_setup_contract_test.sql',
    ).readAsStringSync();
    for (final evidence in [
      'unauthorized role rejected',
      'tenant boundary rejected',
      'identical apply is idempotent',
      'occupied table change rolls back atomically',
      'invalid row blocks all writes',
      'unspecified rows preserved',
      'duplicate active route constrained',
      'summary audit recorded',
      'readiness derives successful recent tests',
      'order and payment contracts do not call readiness',
    ]) {
      expect(contract, contains(evidence));
    }
    expect(contract, contains('ROLLBACK;'));
  });
}
