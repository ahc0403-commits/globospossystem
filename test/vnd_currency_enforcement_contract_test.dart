import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const migrationPath =
    'supabase/migrations/20260718170000_vnd_currency_enforcement.sql';
const preflightPath = 'scripts/preflight_vnd_currency_enforcement.sql';
const verifyPath = 'scripts/verify_vnd_currency_enforcement.sql';
const rollbackPath = 'scripts/rollback_vnd_currency_enforcement.sql';
const deployPath = 'scripts/deploy_pos_production.sh';
const runtimeTestPath = 'supabase/tests/vnd_currency_enforcement_test.sql';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'operational currency columns are normalized and constrained to VND',
    () {
      final migration = readRepoFile(migrationPath);

      expect(migration, contains("upper(btrim(currency)) <> 'VND'"));
      expect(migration, contains('VND_CURRENCY_NON_VND_BRAND_BLOCKED'));
      expect(migration, contains('VND_CURRENCY_NON_VND_EXTERNAL_SALE_BLOCKED'));
      expect(migration, contains("SET currency = 'VND'"));
      expect(migration, contains("ALTER COLUMN currency SET DEFAULT 'VND'"));
      expect(migration, contains('ALTER COLUMN currency SET NOT NULL'));
      expect(
        migration,
        contains('ops_brands_currency_vnd_only_20260718170000'),
      );
      expect(
        migration,
        contains('external_sales_currency_vnd_only_20260718170000'),
      );
      expect(migration, contains("CHECK (currency = 'VND') NOT VALID"));
      expect(migration, contains('VALIDATE CONSTRAINT'));
      expect(migration, isNot(contains('wetax_reference_values')));
    },
  );

  test('non-VND data is blocked before any currency mutation', () {
    final migration = readRepoFile(migrationPath);
    final brandBlock = migration.indexOf('VND_CURRENCY_NON_VND_BRAND_BLOCKED');
    final externalBlock = migration.indexOf(
      'VND_CURRENCY_NON_VND_EXTERNAL_SALE_BLOCKED',
    );
    final firstCurrencyUpdate = migration.indexOf("SET currency = 'VND'");

    expect(brandBlock, greaterThanOrEqualTo(0));
    expect(externalBlock, greaterThanOrEqualTo(0));
    expect(brandBlock, lessThan(firstCurrencyUpdate));
    expect(externalBlock, lessThan(firstCurrencyUpdate));
  });

  test('normalization has owner-only evidence and exact rollback support', () {
    final migration = readRepoFile(migrationPath);
    final rollback = readRepoFile(rollbackPath);

    expect(
      migration,
      contains('vnd_currency_enforcement_20260718170000_backup'),
    );
    expect(
      migration,
      contains('FROM PUBLIC, anon, authenticated, service_role'),
    );
    expect(rollback, contains('VND_CURRENCY_ROLLBACK_BACKUP_MISSING'));
    expect(rollback, contains('SET currency = backup.original_currency'));
    expect(rollback, contains('ALTER COLUMN currency DROP NOT NULL'));
    expect(rollback, contains("ALTER COLUMN currency SET DEFAULT ''"));
    expect(rollback, contains('DROP TABLE public.vnd_currency_enforcement'));
  });

  test('production gate has preflight verification and rollback artifacts', () {
    final deploy = readRepoFile(deployPath);

    for (final path in [
      migrationPath,
      preflightPath,
      verifyPath,
      rollbackPath,
      runtimeTestPath,
    ]) {
      expect(File(path).existsSync(), isTrue, reason: '$path must exist');
    }
    expect(deploy, contains('20260718170000_vnd_currency_enforcement.sql'));
    expect(deploy, contains('preflight_vnd_currency_enforcement.sql'));
    expect(deploy, contains('verify_vnd_currency_enforcement.sql'));
  });

  test('runtime SQL rejects non-VND writes and checks the VND default', () {
    final runtimeTest = readRepoFile(runtimeTestPath);

    expect(runtimeTest, contains("currency = 'USD'"));
    expect(runtimeTest, contains("'USD'"));
    expect(runtimeTest, contains('WHEN check_violation THEN NULL'));
    expect(runtimeTest, contains("v_currency <> 'VND'"));
    expect(runtimeTest, contains('ROLLBACK;'));
  });

  test('runtime currency outputs contain no KRW USD or won symbol', () {
    final files = <File>[];
    for (final root in ['lib', 'supabase/functions']) {
      files.addAll(
        Directory(root)
            .listSync(recursive: true)
            .whereType<File>()
            .where(
              (file) =>
                  file.path.endsWith('.dart') ||
                  file.path.endsWith('.arb') ||
                  file.path.endsWith('.ts'),
            ),
      );
    }
    final source = files.map((file) => file.readAsStringSync()).join('\n');

    expect(source, isNot(contains('KRW')));
    expect(source, isNot(contains('USD')));
    expect(source, isNot(contains('₩')));
    expect(source, contains('VND'));
    expect(source, contains('₫'));
  });

  test('meInvoice transaction payload remains pinned to VND', () {
    final meinvoice = readRepoFile('supabase/functions/_shared/meinvoice.ts');

    expect(meinvoice, contains('CurrencyCode: "VND"'));
    expect(meinvoice, contains('MainCurrency: "VND"'));
    expect(meinvoice, contains('ExchangeRate: 1'));
  });
}
