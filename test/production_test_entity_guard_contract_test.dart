import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const migrationPath =
    'supabase/migrations/20260719013000_production_test_entity_guard.sql';
const preflightPath = 'scripts/preflight_production_test_entity_guard.sql';
const verifyPath = 'scripts/verify_production_test_entity_guard.sql';
const rollbackPath = 'scripts/rollback_production_test_entity_guard.sql';
const runtimePath = 'supabase/tests/production_test_entity_guard_test.sql';
const deployPath = 'scripts/deploy_pos_production.sh';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('production DB rejects test Auth identities at write time', () {
    final migration = readRepoFile(migrationPath);

    expect(
      migration,
      contains('BEFORE INSERT OR UPDATE OF email ON auth.users'),
    );
    expect(migration, contains("@[^@]+[.]test\$"));
    expect(migration, contains('office.super@globos.vn'));
    expect(migration, contains("ERRCODE = '23514'"));
    expect(migration, contains('PRODUCTION_TEST_AUTH_IDENTITY_FORBIDDEN'));
  });

  test('production DB rejects marked brands and restaurants', () {
    final migration = readRepoFile(migrationPath);

    expect(migration, contains('reject_production_test_brand'));
    expect(migration, contains('reject_production_test_restaurant'));
    expect(migration, contains('(test|fixture|smoke|pilot)'));
    expect(migration, contains("LIKE 'SMK\\_%' ESCAPE '\\'"));
    expect(
      migration,
      contains('BEFORE INSERT OR UPDATE OF name, slug, brand_id, is_active'),
    );
  });

  test('guard has preflight, negative probes, verification, and rollback', () {
    for (final path in [
      migrationPath,
      preflightPath,
      verifyPath,
      rollbackPath,
      runtimePath,
    ]) {
      expect(File(path).existsSync(), isTrue, reason: '$path must exist');
    }

    final verify = readRepoFile(verifyPath);
    final rollback = readRepoFile(rollbackPath);
    final runtime = readRepoFile(runtimePath);
    final deploy = readRepoFile(deployPath);

    expect(verify, contains('guard-probe@globos.test'));
    expect(verify, contains('office.super@globos.vn'));
    expect(verify, contains('Guard Fixture Restaurant'));
    expect(
      verify,
      contains('PRODUCTION_TEST_ENTITY_GUARD_VERIFY_PROBE_PERSISTED'),
    );
    expect(rollback, contains('DROP TRIGGER IF EXISTS'));
    expect(runtime, contains('ROLLBACK;'));
    expect(deploy, contains('preflight_production_test_entity_guard.sql'));
    expect(deploy, contains('verify_production_test_entity_guard.sql'));
  });
}
