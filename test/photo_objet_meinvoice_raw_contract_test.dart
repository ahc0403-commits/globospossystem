import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migrationPath =
      'supabase/migrations/20260630007000_photo_objet_raw_meinvoice_queue.sql';
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
    expect(source, contains("PHOTO_OBJET_BIENHOA_ENABLED', true"));
    expect(source, contains('Asia/Ho_Chi_Minh'));
    expect(source, contains('getTargetDates'));
    expect(source, contains('normalizeRawSalesRows'));
    expect(source, contains('source_hash'));
    expect(source, contains("payment_method: 'CASH'"));
    expect(source, contains("buyer_kind: 'anonymous'"));
    expect(source, contains("from('photo_objet_sales_pull_runs')"));
    expect(source, contains("from('photo_objet_sales_raw')"));
    expect(source, contains("onConflict: 'source_hash'"));
    expect(source, contains('upsertRawSalesRows(rawRows)'));
    expect(
      source.indexOf('upsertRawSalesRows(rawRows)'),
      lessThan(source.indexOf("from('photo_objet_sales')")),
    );
    expect(source, contains('pulled_at: new Date().toISOString()'));
    expect(source, isNot(contains('publishCashRegisterInvoice')));
    expect(source, isNot(contains('MISA_MEINVOICE_PASSWORD')));
  });

  test('Photo Objet workflow runs hourly from 09:00 through 22:00 HCM', () {
    final workflow = readRepoFile(workflowPath);

    expect(workflow, contains("cron: '0 2-15 * * *'"));
    expect(workflow, contains('09:00-22:00 Asia/Ho_Chi_Minh'));
    expect(workflow, contains("node-version: '22'"));
    expect(workflow, contains('concurrency:'));
    expect(workflow, contains('cancel-in-progress: false'));
    expect(workflow, isNot(contains('MOERS_D7')));
    expect(workflow, isNot(contains('PHOTO_OBJET_D7')));
    expect(workflow, contains('defaults to today in Asia/Ho_Chi_Minh'));
    expect(workflow, contains('node pull_moers_sales.js'));
  });

  test('Photo Objet setup docs describe raw ledger and queue boundaries', () {
    final docs = readRepoFile(docsPath);

    expect(docs, contains('photo_objet_sales_raw'));
    expect(docs, contains('photo_objet_sales_pull_runs'));
    expect(docs, contains('meinvoice_jobs'));
    expect(docs, contains('The crawler does not call MISA directly.'));
    expect(docs, contains("cron: '0 2-15 * * *'"));
    expect(docs, contains('09:00 through 22:00'));
    expect(docs, isNot(contains('MOERS_D7')));
    expect(docs, isNot(contains('PHOTO_OBJET_D7')));
    expect(docs, contains('payment_method = CASH'));
    expect(docs, contains('VNPAY/QR wallet data must not be mixed'));
  });
}
