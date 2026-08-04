import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/production_gate_test_support.dart';

void main() {
  const migrationName = '20260801070557_photo_objet_zero_amount_raw_rows.sql';

  test('zero-amount raw-row migration has explicit production gates', () {
    final deploy = readProductionGateContract();
    final migration = File(
      'supabase/migrations/$migrationName',
    ).readAsStringSync();
    final preflight = File(
      'scripts/preflight_photo_objet_zero_amount_raw_rows.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_photo_objet_zero_amount_raw_rows.sql',
    ).readAsStringSync();

    expect(deploy, contains(migrationName));
    expect(
      deploy,
      contains('scripts/preflight_photo_objet_zero_amount_raw_rows.sql'),
    );
    expect(
      deploy,
      contains('scripts/verify_photo_objet_zero_amount_raw_rows.sql'),
    );
    expect(migration, contains('CHECK (amount >= 0)'));
    expect(preflight, contains('PHOTO_ZERO_AMOUNT_PRIOR_CONSTRAINT_INVALID'));
    expect(verification, contains('PHOTO_ZERO_AMOUNT_CONSTRAINT_INVALID'));
    expect(verification, contains('PHOTO_ZERO_AMOUNT_INVOICE_TRIGGER_PRESENT'));
  });
}
