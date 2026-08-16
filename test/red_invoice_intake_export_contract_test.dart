import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/production_gate_test_support.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migration =
      'supabase/migrations/20260721040000_red_invoice_intake_export.sql';
  const existingSalesMigration =
      'supabase/migrations/20260716210000_restaurant_sales_excel_export.sql';
  const unifiedMigration =
      'supabase/migrations/20260816120000_unified_restaurant_misa_sales_report.sql';
  const screen =
      'lib/features/red_invoice_intake/red_invoice_intake_screen.dart';
  const modal = 'lib/features/cashier/red_invoice_modal.dart';
  const router = 'lib/core/router/app_router.dart';
  const preflight = 'scripts/preflight_red_invoice_intake_export.sql';
  const verification = 'scripts/verify_red_invoice_intake_export.sql';

  test('unifies Red Invoice data with the all-receipts report', () {
    final salesSql = readRepoFile(existingSalesMigration);
    final redInvoiceSql = readRepoFile(migration);
    final unifiedSql = readRepoFile(unifiedMigration);

    expect(salesSql, contains('get_restaurant_daily_sales_export'));
    expect(salesSql, contains('v_restaurant_sales_receipts'));
    expect(salesSql, isNot(contains('red_invoice_intakes')));
    expect(
      redInvoiceSql,
      contains('CREATE TABLE IF NOT EXISTS public.red_invoice_intakes'),
    );
    expect(
      redInvoiceSql,
      isNot(
        contains(
          'CREATE OR REPLACE FUNCTION public.get_restaurant_daily_sales_export',
        ),
      ),
    );
    expect(unifiedSql, contains('red_invoice_intakes'));
    expect(unifiedSql, contains('get_restaurant_daily_sales_export'));
    expect(unifiedSql, contains('is_red_invoice'));
  });

  test(
    'exports only reviewed records after the immutable daily finalization',
    () {
      final sql = readRepoFile(migration);

      expect(sql, contains('get_red_invoice_daily_export'));
      expect(sql, contains('restaurant_daily_sales_finalizations'));
      expect(sql, contains("v_finalization.status <> 'finalized'"));
      expect(sql, contains("intake.status = 'ready'"));
      expect(sql, contains('RED_INVOICE_MISA_CONFIG_REQUIRED'));
      expect(sql, contains('RED_INVOICE_EXPORT_STATE_CHANGED'));
      expect(sql, contains("SET status = 'exported'"));
    },
  );

  test(
    'preserves original receipt matching and pauses asynchronous dispatch',
    () {
      final sql = readRepoFile(migration);

      expect(sql, contains('receipt_ids text[]'));
      expect(sql, contains('array_agg(payment.id::text'));
      expect(sql, contains("THEN 'dispatch_paused'"));
      expect(sql, contains("THEN 'manual_action_required'"));
      expect(sql, contains("THEN 'buyer_info_after_issue'"));
      expect(sql, contains('RED_INVOICE_INTAKE_LOCKED'));
    },
  );

  test('provides deferred cashier capture without a separate download', () {
    final modalSource = readRepoFile(modal);
    final screenSource = readRepoFile(screen);
    final routerSource = readRepoFile(router);

    expect(modalSource, contains('_RedInvoiceStep.deferred'));
    expect(modalSource, contains("'business_card'"));
    expect(modalSource, contains("'zalo'"));
    expect(modalSource, contains("status: 'awaiting_information'"));
    expect(screenSource, isNot(contains('red_invoice_export_button')));
    expect(screenSource, isNot(contains('FileSaver.instance.saveFile')));
    expect(routerSource, contains("path: '/red-invoice-export'"));
    expect(routerSource, contains("location == '/red-invoice-export'"));
    expect(routerSource, contains("role != 'super_admin'"));
  });

  test('does not duplicate the MISA post-issuance lifecycle', () {
    final sql = readRepoFile(migration);

    expect(sql, isNot(contains('lookup_url')));
    expect(sql, isNot(contains('invoice_pdf')));
    expect(sql, isNot(contains('cancel_invoice')));
    expect(sql, isNot(contains('replace_invoice')));
    expect(sql, isNot(contains('adjust_invoice')));
  });

  test('production deployment has explicit database safety gates', () {
    final deploySource = readProductionGateContract();
    final preflightSource = readRepoFile(preflight);
    final verificationSource = readRepoFile(verification);

    expect(
      deploySource,
      contains('20260721040000_red_invoice_intake_export.sql'),
    );
    expect(deploySource, contains('preflight_red_invoice_intake_export.sql'));
    expect(deploySource, contains('verify_red_invoice_intake_export.sql'));
    expect(preflightSource, contains('RED_INVOICE_BASE_RELATION_MISSING'));
    expect(verificationSource, contains('RED_INVOICE_RLS_INVALID'));
    expect(verificationSource, contains('RED_INVOICE_BUCKET_INVALID'));
    expect(verificationSource, contains('RED_INVOICE_FUNCTION_INVALID'));
    expect(verificationSource, contains('RED_INVOICE_PRIVILEGE_INVALID'));
  });
}
