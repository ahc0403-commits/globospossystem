import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'helpers/production_gate_test_support.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migration =
      'supabase/migrations/20260816120000_unified_restaurant_misa_sales_report.sql';
  const pilotMigration =
      'supabase/migrations/20260816153000_sample_misa_sales_pilot.sql';
  const allStoresMigration =
      'supabase/migrations/20260816170000_restaurant_sales_export_all_stores.sql';
  const contactMigration =
      'supabase/migrations/20260816180000_red_invoice_contact_fields.sql';
  const pilotPreflight = 'scripts/preflight_sample_misa_sales_pilot.sql';
  const screen =
      'lib/features/restaurant_sales_export/restaurant_sales_export_screen.dart';
  const superAdmin = 'lib/features/super_admin/super_admin_screen.dart';

  test('unified RPC exports finalized Restaurant POS receipts only', () {
    final sql = readRepoFile(migration);
    final finalSql = readRepoFile(allStoresMigration);
    final finalFunction = finalSql.substring(
      finalSql.indexOf(
        'CREATE OR REPLACE FUNCTION public.get_restaurant_daily_sales_export',
      ),
      finalSql.indexOf(
        'REVOKE ALL ON FUNCTION public.get_restaurant_daily_sales_export',
      ),
    );

    expect(sql, contains('get_restaurant_daily_sales_export'));
    expect(sql, contains('public.is_super_admin()'));
    expect(sql, contains('restaurant_daily_sales_finalizations'));
    expect(sql, contains("v_finalization.status <> 'finalized'"));
    expect(sql, contains('restaurant_cutoff_policies'));
    expect(finalFunction, isNot(contains('restaurant_cutoff_policies')));
    expect(finalSql, contains("AT TIME ZONE 'Asia/Ho_Chi_Minh'"));
    expect(finalSql, contains('payment.is_revenue = true'));
    expect(sql, contains('77000000-0000-0000-0000-000000000001'));
    expect(sql, contains("'restaurant_pos'::text AS source_system"));
    expect(sql, contains("candidate.source_system = 'restaurant_pos'"));
    expect(sql, contains("'pos_payment'::text AS receipt_source"));
    expect(sql, contains("issued_order.status = 'completed'"));
    expect(sql, contains('HAVING max(payment.created_at) >= v_start'));
    expect(sql, isNot(contains('external_sales_events')));
    expect(sql, contains('line_items_snapshot'));
    expect(sql, contains('red_invoice_intakes'));
    expect(sql, contains('red_invoice_status'));
    expect(sql, contains('buyer_tax_code'));
    expect(sql, contains('buyer_legal_name'));
    expect(sql, contains('buyer_address'));
    expect(sql, contains('REVOKE ALL'));
    expect(sql, contains('TO authenticated'));
  });

  test('Red Invoice intake and export require both contact fields', () {
    final sql = readRepoFile(contactMigration);
    final service = readRepoFile(
      'lib/features/red_invoice_intake/red_invoice_intake_service.dart',
    );

    expect(sql, contains('upsert_red_invoice_intake_minimal'));
    expect(sql, contains('p_buyer_tax_code text DEFAULT NULL'));
    expect(sql, contains('p_buyer_legal_name text DEFAULT NULL'));
    expect(sql, contains('p_buyer_address text DEFAULT NULL'));
    expect(sql, contains('p_buyer_email text DEFAULT NULL'));
    expect(sql, contains('p_buyer_phone text DEFAULT NULL'));
    expect(sql, contains("'buyer_email'"));
    expect(sql, contains("'buyer_phone'"));
    final minimalStart = sql.indexOf(
      'CREATE FUNCTION public.upsert_red_invoice_intake_minimal',
    );
    final minimalSignatureEnd = sql.indexOf(') RETURNS jsonb', minimalStart);
    final signature = sql.substring(minimalStart, minimalSignatureEnd);
    expect(signature, contains('p_buyer_email'));
    expect(signature, contains('p_buyer_phone'));
    expect(signature, isNot(contains('p_buyer_id')));
    expect(service, contains("'upsert_red_invoice_intake_minimal'"));
    expect(service, contains("'p_buyer_email'"));
    expect(service, contains("'p_buyer_phone'"));
  });

  test('Super Admin exposes one MISA download surface', () {
    final screenSource = readRepoFile(screen);
    final superAdminSource = readRepoFile(superAdmin);
    final redScreen = readRepoFile(
      'lib/features/red_invoice_intake/red_invoice_intake_screen.dart',
    );
    final queueScreen = readRepoFile(
      'lib/features/admin/tabs/einvoice_tab.dart',
    );

    expect(superAdminSource, contains('super_admin_nav_sales_tax_report'));
    expect(superAdminSource, contains('매출신고 하기'));
    expect(
      superAdminSource,
      contains('RestaurantSalesExportScreen(embedded: true)'),
    );
    expect(
      superAdminSource,
      isNot(contains('super_admin_restaurant_sales_export_link')),
    );
    expect(
      superAdminSource,
      isNot(contains('super_admin_red_invoice_export_link')),
    );
    expect(screenSource, contains('restaurant_sales_export_preview'));
    expect(screenSource, contains('restaurant_sales_export_button'));
    expect(screenSource, contains('MISA_restaurant_sales_'));
    expect(screenSource, contains("ext: 'xlsx'"));
    expect(redScreen, isNot(contains('red_invoice_export_button')));
    expect(queueScreen, isNot(contains('misa_pending_excel_download')));
  });

  test('sales report supports explicit past-date search and download', () {
    final screenSource = readRepoFile(screen);

    expect(screenSource, contains('restaurant_sales_export_date_search'));
    expect(screenSource, contains('restaurant_sales_export_date_picker'));
    expect(screenSource, contains('restaurant_sales_export_search'));
    expect(
      screenSource,
      contains('restaurant_sales_export_past_date_guidance'),
    );
    expect(screenSource, contains('firstDate: DateTime(2020)'));
    expect(screenSource, contains('lastDate: hcmToday'));
    expect(screenSource, contains("_businessDate.replaceAll('-', '')"));
  });

  test(
    'sample pilot keeps one general receipt and prepares two Red Invoices',
    () {
      final sql = readRepoFile(pilotMigration);
      final preflight = readRepoFile(pilotPreflight);

      expect(sql, contains('BunsikClub SAMPLE'));
      expect(sql, contains('2026-08-15'));
      expect(sql, contains('dee5df02-b080-4a4a-a6b7-eefebdc5c4ba'));
      expect(sql, contains('b80806b5-b496-472a-b250-ea83b90209b0'));
      expect(sql, contains('a584f119-8bfd-4e79-842e-4e19574d1b3f'));
      expect(sql, contains('SAMPLE_MISA_PILOT_GENERAL_RECEIPT_CHANGED'));
      expect(sql, contains("'ready'"));
      expect(sql, contains("status = 'dispatch_paused'"));
      expect(sql, contains("'test_data_only', true"));
      expect(sql, contains('buyer_email IS NULL'));
      expect(sql, contains('buyer_phone IS NULL'));
      expect(sql, contains('buyer_id IS NULL'));
      expect(preflight, contains('SAMPLE_MISA_PILOT_SALES_CHANGED'));
      expect(preflight, contains('SAMPLE_MISA_PILOT_ALREADY_CONFIGURED'));
    },
  );

  test('migration is discoverable by the self-verifying production gate', () {
    final deployment = readProductionGateContract();

    expect(
      deployment,
      contains('20260816120000_unified_restaurant_misa_sales_report.sql'),
    );
    expect(
      readRepoFile(migration),
      contains('-- production-gate: self-verifying'),
    );
    expect(deployment, contains('production-gate: self-verifying'));
  });
}
