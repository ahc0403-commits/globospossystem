import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migrationPath =
      'supabase/migrations/20260630000000_wetax_shutdown_meinvoice_foundation.sql';

  test('migration permanently shuts down new WeTax dispatch paths', () {
    final sql = readRepoFile(migrationPath);

    expect(sql, contains("'wetax_dispatch_enabled'"));
    expect(sql, contains("'wetax_polling_enabled'"));
    expect(sql, contains("'wetax_shutdown_permanent'"));
    expect(sql, contains("'false'"));
    expect(sql, contains('cron.unschedule(jobname)'));
    expect(sql, contains("'wetax-dispatcher-every-minute'"));
    expect(sql, contains("'wetax-poller-every-2-minutes'"));
    expect(sql, contains("'wetax-daily-close-00-hcmc'"));
    expect(sql, contains("'wetax-commons-refresh-weekly'"));
    expect(sql, contains('block_wetax_einvoice_job_insert'));
    expect(sql, contains('RETURN NULL;'));
    expect(sql, contains("SET einvoice_provider = 'meinvoice'"));
    expect(sql, contains("tax_code <> 'PLACEHOLDER_DEV_000'"));
    expect(sql, isNot(contains("cron.schedule(\n      'wetax")));
  });

  test('migration introduces meInvoice cash-register first-issuance queue', () {
    final sql = readRepoFile(migrationPath);

    expect(sql, contains('CREATE TABLE IF NOT EXISTS public.meinvoice_jobs'));
    expect(sql, contains("provider text NOT NULL DEFAULT 'meinvoice'"));
    expect(sql, contains("invoice_form text NOT NULL DEFAULT 'cash_register'"));
    expect(sql, contains('UNIQUE (order_id)'));
    expect(sql, contains('buyer_snapshot jsonb NOT NULL'));
    expect(sql, contains('payment_method_snapshot text NOT NULL'));
    expect(sql, contains('payment_summary jsonb NOT NULL'));
    expect(sql, contains('line_items_snapshot jsonb NOT NULL'));
    expect(sql, contains('misa_ref_id text'));
    expect(sql, contains('transaction_id text'));
    expect(sql, contains('tax_authority_code text'));
    expect(sql, contains('search_code text'));
  });

  test(
    'restaurant order completion enqueues meInvoice without blocking payment',
    () {
      final sql = readRepoFile(migrationPath);

      expect(sql, contains('enqueue_meinvoice_cash_register_job'));
      expect(sql, contains('AFTER UPDATE OF status ON public.orders'));
      expect(sql, contains("WHEN (NEW.status = 'completed')"));
      expect(sql, contains('EXCEPTION'));
      expect(sql, contains('RETURN NEW;'));
      expect(sql, contains("'Người mua không lấy hóa đơn'"));
      expect(sql, contains("v_tax_code = 'PLACEHOLDER_DEV_000'"));
    },
  );

  test(
    'request red invoice now updates meInvoice and leaves exceptions manual',
    () {
      final sql = readRepoFile(migrationPath);

      expect(
        sql,
        contains('CREATE OR REPLACE FUNCTION public.request_red_invoice'),
      );
      expect(sql, contains('public.meinvoice_jobs%ROWTYPE'));
      expect(sql, contains("'request_red_invoice'"));
      expect(sql, contains("'meinvoice_jobs'"));
      expect(sql, contains("'manual_action_required'"));
      expect(sql, contains("'buyer_info_after_issue'"));
      expect(
        sql,
        contains('handle replace/adjust/incorrect-invoice notice manually'),
      );
      expect(sql, isNot(contains("UPDATE einvoice_jobs\n  SET")));
    },
  );

  test('Flutter buyer lookup no longer calls WeTax onboarding', () {
    final source = readRepoFile('lib/core/services/einvoice_service.dart');

    expect(source, isNot(contains("'wetax-onboarding'")));
    expect(source, isNot(contains('WT09 lookup failed')));
    expect(source, isNot(contains('lookupCompanyByTaxCode')));
    expect(source, contains('lookupB2bBuyer'));
  });
}
