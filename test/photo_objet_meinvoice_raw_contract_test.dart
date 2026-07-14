import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const rawMigration =
      'supabase/migrations/20260630007000_photo_objet_raw_meinvoice_queue.sql';
  const intervalMigration =
      'supabase/migrations/20260712190000_photo_objet_interval_ledger.sql';
  const immutableMigration =
      'supabase/migrations/20260713090000_photo_objet_immutable_health.sql';
  const slotMigration =
      'supabase/migrations/20260713120000_photo_objet_expected_slot_ledger.sql';
  const slotApply = 'scripts/apply_photo_objet_expected_slot_ledger.sql';
  const slotConfiguration =
      'scripts/configure_photo_objet_monitoring_policies.sql';
  const collector = 'scripts/pull_moers_sales.js';
  const health = 'scripts/photo_objet_slot_health.js';
  const docs = 'docs/photo_objet_sales_pull_setup.md';

  test('Photo Objet raw sales remain immutable and MISA-independent', () {
    final sql = readRepoFile(rawMigration);
    final source = readRepoFile(collector);

    expect(sql, contains('photo_objet_sales_raw'));
    expect(sql, contains('photo_objet_sales_pull_runs'));
    expect(sql, contains('UNIQUE (source_hash)'));
    expect(sql, contains('user_accessible_stores(auth.uid())'));
    expect(sql, isNot(contains('cron.schedule')));
    expect(source, contains('assertImmutableSourceRows'));
    expect(source, contains('SOURCE_IDENTITY_VERSION = 2'));
    expect(source, contains("payment_method: 'CASH'"));
    expect(source, isNot(contains('publishCashRegisterInvoice')));
    expect(source, isNot(contains('MISA_MEINVOICE_PASSWORD')));
    expect(source, isNot(contains('DELETE FROM public.photo_objet_sales_raw')));
  });

  test('collector uses exact typed slots and never performs health audit', () {
    final source = readRepoFile(collector);

    expect(source, contains('run_source: identity.source'));
    expect(source, contains('slot_date_hcm: identity.slotDateHcm'));
    expect(source, contains('slot_time_hcm: identity.slotTimeHcm'));
    expect(source, contains('selectRowsForInterval'));
    expect(source, contains('zeroSalesInterval = selectedRows.length === 0'));
    expect(source, contains('interval_rows: selectedRows.length'));
    expect(source, contains('photo_objet_complete_expected_slot'));
    expect(source, contains('AUDIT_INFRA_FAILED'));
    expect(source, contains('ledger_probe='));
    expect(source, isNot(contains('--audit-missing-runs')));
    expect(source, isNot(contains('RUN_METADATA_AUDIT_START_AT')));
    expect(source, isNot(contains('parseRunMetadata')));
    expect(source, isNot(contains('FLARE_RUN_METADATA')));
  });

  test('expected-slot ledger is policy-driven, scoped, and replay-safe', () {
    final sql = readRepoFile(slotMigration);

    expect(sql, contains('photo_objet_monitoring_policies'));
    expect(sql, contains('photo_objet_expected_slots'));
    expect(sql, contains('UNIQUE (store_id, slot_date_hcm, slot_time_hcm)'));
    for (final status in [
      'expected',
      'running',
      'collected',
      'collected_zero',
      'missing',
      'failed',
      'recovered',
    ]) {
      expect(sql, contains("'$status'"));
    }
    for (final slot in [
      '10:00',
      '12:00',
      '14:00',
      '16:00',
      '18:00',
      '20:00',
      '23:00',
    ]) {
      expect(sql, contains("TIME '$slot'"));
    }
    for (final removedSlot in ['09:00', '11:00', '22:00', '22:30']) {
      expect(sql, isNot(contains("(TIME '$removedSlot')")));
    }
    expect(sql, contains("st.slot_time = TIME '23:00'"));
    expect(sql, contains("DEFAULT 'hcm-two-hour-v1'"));
    expect(sql, contains('DEFAULT 90'));
    expect(sql, contains('photo_objet_ensure_expected_slots'));
    expect(sql, contains('photo-objet-materialize-expected-slots'));
    expect(sql, contains("'5 17 * * *'"));
    expect(
      sql,
      contains('ON CONFLICT (store_id, slot_date_hcm, slot_time_hcm)'),
    );
    expect(sql, contains('public.is_super_admin()'));
    expect(sql, contains('user_accessible_stores(auth.uid())'));
    expect(sql, contains('eligible.store_id = health.store_id'));
    expect(sql, contains('alerted_failure_class IS DISTINCT FROM'));
    expect(sql, contains('photo_objet_ack_expected_slot_alert'));
    expect(sql, contains('FROM PUBLIC, anon, authenticated, service_role'));
    expect(
      sql,
      contains('REVOKE ALL ON public.photo_slot_20260713120000_state'),
    );
    expect(sql, contains('coverage_missing_slots'));
    expect(sql, contains('r.interval_rows = 0 AS zero_sales'));
    expect(sql, isNot(contains("'2026-07-13 09:00")));
    expect(sql, isNot(contains('126')));
    expect(sql, isNot(contains('DELETE FROM public.photo_objet_sales_raw')));
  });

  test('legacy immutable migration remains represented on main', () {
    final sql = readRepoFile(immutableMigration);

    expect(sql, contains('enforce_photo_objet_raw_immutability'));
    expect(sql, contains('PHOTO_OBJET_RAW_IDENTITY_IMMUTABLE'));
    expect(sql, contains('PHOTO_OBJET_RAW_DELETE_FORBIDDEN'));
    expect(sql, contains('v_photo_objet_collection_health'));
  });

  test(
    'interval migration retains backup and immutable identity contracts',
    () {
      final sql = readRepoFile(intervalMigration);

      expect(sql, contains('photo_interval_20260712190000_raw_backup'));
      expect(
        sql,
        contains('source_identity_version integer NOT NULL DEFAULT 2'),
      );
      expect(sql, contains('occurrence_no integer'));
      expect(sql, contains('interval_start_at'));
      expect(sql, contains('interval_end_at'));
      expect(sql, contains('run_source'));
      expect(sql, contains('slot_date_hcm'));
      expect(sql, contains('slot_time_hcm'));
    },
  );

  test('health audit is credential-minimal, typed, and fail-closed', () {
    final source = readRepoFile(health);

    expect(source, contains('photo_objet_refresh_expected_slot_health'));
    expect(source, contains('photo_objet_expected_slot_health_at'));
    expect(source, contains('photo_objet_ack_expected_slot_alert'));
    expect(source, contains("audit_result: (rows || []).length === 0"));
    expect(source, contains('AUDIT_INFRA_FAILED'));
    expect(source, isNot(contains('MOERS_')));
    expect(source, isNot(contains('puppeteer')));
    expect(source, isNot(contains('error_message')));
  });

  test('workflows split collection, health, backfill, contract, and release', () {
    final collect = readRepoFile(
      '.github/workflows/photo_objet_sales_collect.yml',
    );
    final slotHealth = readRepoFile(
      '.github/workflows/photo_objet_sales_health.yml',
    );
    final backfill = readRepoFile(
      '.github/workflows/photo_objet_sales_backfill.yml',
    );
    final contract = readRepoFile(
      '.github/workflows/photo_objet_sales_contract.yml',
    );
    final release = readRepoFile(
      '.github/workflows/photo_objet_release_proof.yml',
    );

    final collectionCrons = RegExp(
      r"cron: '([^']+)'",
    ).allMatches(collect).map((match) => match.group(1)).toList();
    expect(collectionCrons, [
      '0 3 * * *',
      '0 5 * * *',
      '0 7 * * *',
      '0 9 * * *',
      '0 11 * * *',
      '0 13 * * *',
      '0 16 * * *',
    ]);
    expect(collect, contains("node-version: '22'"));
    expect(collect, contains('npm ci'));
    expect(collect, contains('npx puppeteer browsers install'));
    expect(collect, isNot(contains('--install-deps')));
    expect(collect, isNot(contains('audit-missing-runs')));
    expect(collect, isNot(contains('backfill')));

    for (final hour in [4, 6, 8, 10, 12, 14, 17]) {
      expect(slotHealth, contains("cron: '40 $hour * * *'"));
    }
    expect(slotHealth, contains('--refresh --output health-evidence.json'));
    expect(slotHealth, contains('--ack-file health-evidence.json'));
    expect(slotHealth, contains('--assert-file health-evidence.json'));
    expect(slotHealth, isNot(contains('MOERS_')));
    expect(slotHealth, isNot(contains('Chromium')));

    expect(backfill, contains('workflow_dispatch:'));
    expect(backfill, contains('default: false'));
    expect(backfill, contains('EXECUTE_IMMUTABLE_BACKFILL'));
    expect(backfill, isNot(contains('schedule:')));
    expect(contract, contains('pull_request:'));
    expect(contract, isNot(contains('secrets.')));

    expect(release, contains('branches: [main]'));
    expect(release, contains('git merge-base --is-ancestor'));
    expect(release, contains('PRODUCTION_DEPLOYED exact main SHA'));
    expect(release, contains('--read-only --output release-health.json'));
    expect(release, contains('globospossystem.vercel.app'));
    expect(release, contains('release-proof-evidence.json'));

    final apply = readRepoFile(slotApply);
    final configuration = readRepoFile(slotConfiguration);
    expect(
      apply,
      contains(
        r'\ir ../supabase/migrations/20260713120000_photo_objet_expected_slot_ledger.sql',
      ),
    );
    expect(
      apply,
      contains(r'\ir configure_photo_objet_monitoring_policies.sql'),
    );
    expect(configuration, contains('approved_photo_objet_monitoring_stores'));
    expect(configuration, contains('photo_objet_ensure_expected_slots'));
  });

  test('SheetJS stays on the patched vendored release', () {
    final packageJson = readRepoFile('scripts/package.json');
    final packageLock = readRepoFile('scripts/package-lock.json');

    expect(packageJson, contains('file:vendor/xlsx-0.20.3.tgz'));
    expect(packageLock, contains('xlsx-0.20.3.tgz'));
    expect(packageLock, isNot(contains('"version": "0.18.5"')));
  });

  test(
    'runbook documents immutable, independent, and exact-main boundaries',
    () {
      final text = readRepoFile(docs);

      expect(text, contains('immutable source'));
      expect(text, contains('collected_zero'));
      expect(text, contains('90-minute grace'));
      expect(
        text,
        contains(
          'detect -> create or update exact store/slot/failure issue -> ACK',
        ),
      );
      expect(
        text,
        contains(
          'PR checks and Preview deployments are never operational PASS',
        ),
      );
      expect(text, contains('MISA queueing and receipt automation'));
      expect(text, contains('dry-run by default'));
      expect(text, contains('60 stores/420 slots'));
      expect(text, isNot(contains('126')));
    },
  );
}
