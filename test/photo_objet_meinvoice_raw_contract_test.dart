import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migrationPath =
      'supabase/migrations/20260630007000_photo_objet_raw_meinvoice_queue.sql';
  const intervalMigrationPath =
      'supabase/migrations/20260712190000_photo_objet_interval_ledger.sql';
  const immutableHealthMigrationPath =
      'supabase/migrations/20260713090000_photo_objet_immutable_health.sql';
  const scriptPath = 'scripts/pull_moers_sales.js';
  const workflowPath = '.github/workflows/photo_objet_sales.yml';
  const docsPath = 'docs/photo_objet_sales_pull_setup.md';

  test('Photo Objet raw ledger migration extends meInvoice safely', () {
    final sql = readRepoFile(migrationPath);

    expect(sql, contains('photo_objet_sales_raw'));
    expect(sql, contains('photo_objet_sales_pull_runs'));
    expect(sql, contains('ALTER COLUMN order_id DROP NOT NULL'));
    expect(sql, contains('source_system text NOT NULL'));
    expect(sql, contains('source_key text'));
    expect(sql, contains('source_snapshot jsonb'));
    expect(sql, contains('meinvoice_jobs_source_key_unique'));
    expect(sql, contains("'photo_objet_moers'"));
    expect(sql, contains("payment_method text NOT NULL DEFAULT 'CASH'"));
    expect(sql, contains("CHECK (payment_method = 'CASH')"));
    expect(sql, contains('UNIQUE (source_hash)'));
    expect(
      sql,
      contains(
        'CREATE OR REPLACE FUNCTION public.enqueue_photo_objet_meinvoice_job',
      ),
    );
    expect(sql, contains('AFTER INSERT ON public.photo_objet_sales_raw'));
    expect(sql, contains('public.meinvoice_payment_method_label'));
    expect(sql, contains("ARRAY['CASH']::text[]"));
    expect(sql, contains("'Người mua không lấy hóa đơn'"));
    expect(sql, contains("'pending_manual_config'"));
    expect(sql, contains("'pending'"));
    expect(sql, contains('ENABLE ROW LEVEL SECURITY'));
    expect(sql, contains('user_accessible_stores(auth.uid())'));
    expect(sql, isNot(contains('cron.schedule')));
    expect(sql, isNot(contains('publishCashRegisterInvoice')));
  });

  test('Moers pull script stores raw rows before dashboard aggregate', () {
    final source = readRepoFile(scriptPath);

    expect(source, contains("const crypto = require('crypto');"));
    expect(source, isNot(contains('MOERS_D7')));
    expect(source, isNot(contains('PHOTO_OBJET_D7')));
    expect(source, contains("['BIEN HOA', 'BIENHOA']"));
    expect(source, contains('Asia/Ho_Chi_Minh'));
    expect(source, contains('getTargetDates'));
    expect(source, contains('--preflight-only'));
    expect(source, contains('Node 22 is required'));
    expect(source, contains('Node WebSocket global is unavailable'));
    expect(source, contains('EXPECTED_POS_PROJECT_REF'));
    expect(source, contains('validateStoreMappings'));
    expect(source, contains(r'`PHOTO OBJET ${store.storeName}`'));
    expect(source, contains("replace(/\\s+/g, ' ')"));
    expect(source, contains('photo_objet_sales_pull_runs'));
    expect(source, contains('photo_objet_sales_raw'));
    expect(source, contains('RUN_METADATA_PREFIX'));
    expect(source, contains('RUN_METADATA_AUDIT_START_AT'));
    expect(source, contains("Date.parse('2026-07-13T02:00:00Z')"));
    expect(source, contains('if (slot.at < auditStartAt) continue;'));
    expect(source, contains('AUDIT_HISTORICAL_BASELINE'));
    expect(source, contains("metadata?.source === 'scheduled'"));
    expect(source, contains('metadata.slot_id === slot.slotId'));
    expect(source, isNot(contains("metadata.slot_time_hcm >= slot.label.slice(-5)")));
    expect(source, isNot(contains('startedAt >= slot.at')));
    expect(source, contains('salesTableFromMatrix'));
    expect(source, contains('if (table.recognized) return table.rows;'));
    expect(
      source,
      contains(
        "throw transient('Downloaded spreadsheet has no recognizable sales table')",
      ),
    );
    expect(source, contains('runWithTransientRetry'));
    expect(source, contains('attempt < 2'));
    expect(source, contains('--audit-missing-runs'));
    expect(source, contains('MAX_BACKFILL_DAYS = 7'));
    expect(source, contains('BACKFILL_DRY_RUN'));
    expect(source, contains('assertAggregateComplete'));
    expect(source, contains('normalizeRawSalesRows'));
    expect(source, contains('selectRowsForInterval'));
    expect(source, contains('SOURCE_IDENTITY_VERSION = 2'));
    expect(source, isNot(contains('row_index: index')));
    expect(source, contains('source_hash'));
    expect(source, contains("payment_method: 'CASH'"));
    expect(source, contains("buyer_kind: 'anonymous'"));
    expect(source, contains("from('photo_objet_sales_pull_runs')"));
    expect(source, contains("from('photo_objet_sales_raw')"));
    expect(source, contains("onConflict: 'source_hash'"));
    expect(source, contains('ignoreDuplicates: true'));
    expect(source, contains('assertImmutableSourceRows'));
    expect(source, contains('upsertRawSalesRows(supabase, rawRows)'));
    expect(
      source.indexOf('upsertRawSalesRows(supabase, rawRows)'),
      lessThan(source.indexOf('.upsert(payload')),
    );
    expect(source, contains('pulled_at: new Date().toISOString()'));
    expect(source, isNot(contains('publishCashRegisterInvoice')));
    expect(source, isNot(contains('MISA_MEINVOICE_PASSWORD')));
  });

  test('Photo Objet immutable ledger exposes canonical slot health', () {
    final sql = readRepoFile(immutableHealthMigrationPath);

    expect(sql, contains('enforce_photo_objet_raw_immutability'));
    expect(sql, contains('PHOTO_OBJET_RAW_IDENTITY_IMMUTABLE'));
    expect(sql, contains('PHOTO_OBJET_RAW_DELETE_FORBIDDEN'));
    expect(sql, contains('photo_objet_collection_health_at'));
    expect(sql, contains('v_photo_objet_collection_health'));
    expect(sql, contains("'09:00'::time"));
    expect(sql, contains("'22:30'::time"));
    expect(sql, contains("interval '15 minutes'"));
    expect(sql, contains('missing_slot_times'));
    expect(sql, contains('failed_slot_times'));
    expect(sql, contains("'not_due'"));
  });

  test('Photo Objet interval migration backs up, gates, and resets the ledger', () {
    final sql = readRepoFile(intervalMigrationPath);

    expect(sql, contains('photo_interval_20260712190000_jobs_backup'));
    expect(sql, contains('photo_interval_20260712190000_raw_backup'));
    expect(sql, contains("source_system = 'photo_objet_moers'"));
    expect(sql, contains("sales.sale_date < DATE '2026-07-01'"));
    expect(sql, contains('source_identity_version integer NOT NULL DEFAULT 2'));
    expect(sql, contains('occurrence_no integer'));
    expect(sql, contains('ALTER COLUMN sold_at SET NOT NULL'));
    expect(sql, contains("'photo_objet_meinvoice_dispatch_enabled'"));
    expect(sql, contains("'false'"));
    expect(sql, contains('PHOTO_INTERVAL_PREFLIGHT_DISPATCHED_JOBS'));
  });

  test('Photo Objet spreadsheet parser uses patched SheetJS release', () {
    final packageJson = File('scripts/package.json').readAsStringSync();
    final packageLock = File('scripts/package-lock.json').readAsStringSync();

    expect(packageJson, contains('file:vendor/xlsx-0.20.3.tgz'));
    expect(packageLock, contains('xlsx-0.20.3.tgz'));
    expect(packageLock, isNot(contains('"version": "0.18.5"')));
  });

  test(
    'Photo Objet workflow ends collection and invoice queueing at 22:30 HCM',
    () {
      final workflow = readRepoFile(workflowPath);
      final cronExpressions = RegExp(
        r"cron: '([^']+)'",
      ).allMatches(workflow).map((match) => match.group(1)).toList();

      expect(cronExpressions, [
        for (var hour = 2; hour <= 15; hour++) '0 $hour * * *',
        '30 15 * * *',
      ]);
      expect(workflow, contains('09:00-22:30 Asia/Ho_Chi_Minh'));
      expect(workflow, contains('pull_request:'));
      expect(workflow, contains('name: Photo Objet contract'));
      expect(workflow, contains("if: github.event_name == 'pull_request'"));
      expect(workflow, contains("if: github.event_name != 'pull_request'"));
      expect(workflow, contains('npm run security-scan\n          npm test'));
      expect(workflow, contains("node-version: '22'"));
      expect(workflow, contains('npm ci'));
      expect(
        workflow,
        contains(r'npx puppeteer browsers install "chrome@${CHROME_VERSION}"'),
      );
      expect(workflow, isNot(contains('--install-deps')));
      expect(workflow, contains('scripts/package-lock.json'));
      expect(workflow, isNot(contains(r'${{ runner.temp }}')));
      expect(
        workflow,
        contains(
          r'echo "PUPPETEER_CACHE_DIR=${RUNNER_TEMP}/puppeteer" >> "${GITHUB_ENV}"',
        ),
      );
      final productionJob = workflow.substring(
        workflow.indexOf('  pull-sales:'),
      );
      expect(
        productionJob.indexOf(
          r'PUPPETEER_CACHE_DIR=${RUNNER_TEMP}/puppeteer',
        ),
        lessThan(productionJob.indexOf('uses: actions/setup-node@v4')),
      );
      expect(workflow, contains('concurrency:'));
      expect(workflow, contains('cancel-in-progress: false'));
      expect(workflow, contains('--preflight-only'));
      expect(workflow, contains('--audit-missing-runs'));
      expect(workflow, contains('Deduplicate failure escalation'));
      expect(workflow, contains('always() &&'));
      expect(workflow, contains("steps.node_setup.outcome != 'success'"));
      expect(workflow, contains("steps.setup.outcome != 'success'"));
      expect(workflow, contains("steps.chromium.outcome != 'success'"));
      expect(workflow, contains('issues.find'));
      expect(workflow, isNot(contains('MOERS_D7')));
      expect(workflow, isNot(contains('PHOTO_OBJET_D7')));
      expect(workflow, contains('defaults to today in Asia/Ho_Chi_Minh'));
      expect(workflow, contains('node pull_moers_sales.js'));
    },
  );

  test('Photo Objet setup docs describe raw ledger and queue boundaries', () {
    final docs = readRepoFile(docsPath);

    expect(docs, contains('photo_objet_sales_raw'));
    expect(docs, contains('photo_objet_sales_pull_runs'));
    expect(docs, contains('meinvoice_jobs'));
    expect(docs, contains('The crawler does not call MISA directly.'));
    expect(docs, contains("cron: '0 2 * * *'"));
    expect(docs, contains("cron: '30 15 * * *'"));
    expect(docs, contains('09:00 through 22:30'));
    expect(docs, contains('final sales collection and invoice queueing run'));
    expect(docs, isNot(contains('MOERS_D7')));
    expect(docs, isNot(contains('PHOTO_OBJET_D7')));
    expect(docs, contains('payment_method = CASH'));
    expect(docs, contains('VNPAY/QR wallet data must not be mixed'));
    expect(docs, contains('dry-run by default'));
    expect(docs, contains('at most seven inclusive dates'));
    expect(docs, contains('FLARE_FAILURE_CLASS=deterministic'));
    expect(docs, contains('FLARE_RUN_METADATA'));
    expect(docs, contains('`started_at` is not used as slot'));
    expect(docs, contains('2026-07-13 09:00 HCM'));
    expect(docs, contains('126'));
    expect(docs, contains('historical baseline'));
    expect(docs, contains('immutable append-only source'));
    expect(docs, contains('v_photo_objet_collection_health'));
    expect(docs, contains('Photo Objet contract'));
    expect(docs, contains('Vercel preview'));
  });
}
