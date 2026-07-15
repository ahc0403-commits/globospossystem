import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const migrationPath =
    'supabase/migrations/20260715000000_security_audit_hardening.sql';

String section(String source, String start, String end) {
  final startIndex = source.indexOf(start);
  final endIndex = source.indexOf(end, startIndex + start.length);
  expect(startIndex, greaterThanOrEqualTo(0));
  expect(endIndex, greaterThan(startIndex));
  return source.substring(startIndex, endIndex);
}

void main() {
  late String migration;

  setUpAll(() {
    migration = File(migrationPath).readAsStringSync();
  });

  test('sensitive views use invoker RLS and deny anonymous reads', () {
    const views = [
      'store_settings',
      'v_store_daily_sales',
      'v_store_attendance_summary',
      'v_inventory_status',
      'v_brand_kpi',
      'v_quality_monitoring',
      'v_qsc_dashboard_summary',
      'v_qsc_store_status',
      'v_qsc_item_status',
      'v_office_qsc_dashboard',
      'v_office_qsc_store_latest',
      'v_office_qsc_issue_queue',
    ];

    for (final view in views) {
      expect(
        migration,
        contains('ALTER VIEW public.$view SET (security_invoker = true);'),
      );
      expect(
        migration,
        contains('REVOKE ALL ON TABLE public.$view FROM PUBLIC, anon;'),
      );
      expect(
        migration,
        contains('GRANT SELECT ON TABLE public.$view TO authenticated;'),
      );
      expect(
        migration,
        contains('GRANT SELECT ON TABLE public.$view TO service_role;'),
      );
    }

    expect(migration, contains('SECURITY_HARDENING_REQUIRED_VIEWS_MISSING'));
  });

  test('permissive audit policy and internal function grants are removed', () {
    final internalFunctions = section(
      migration,
      '-- 3. Internal definer helpers',
      '-- 4. Canonical identity helpers',
    );

    expect(
      migration,
      contains(
        'DROP POLICY IF EXISTS audit_logs_authenticated_select '
        'ON public.audit_logs;',
      ),
    );
    for (final signature in [
      'public.refresh_user_claims(uuid)',
      'public.sync_all_store_access()',
      'public.sync_brand_store_access(uuid)',
      'public.sync_user_store_access(uuid)',
      'public.refresh_qc_check_photo_summary(uuid,boolean)',
      'public.recalculate_inventory_purchase_order_totals(uuid)',
      'public.enqueue_photo_objet_meinvoice_job(uuid)',
    ]) {
      expect(internalFunctions, contains("'$signature'"));
    }
    expect(
      internalFunctions,
      contains("'REVOKE ALL ON FUNCTION %s FROM PUBLIC, anon, authenticated'"),
    );
    expect(
      internalFunctions,
      contains("'GRANT EXECUTE ON FUNCTION %s TO service_role'"),
    );
    expect(
      internalFunctions,
      contains(
        'ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public\n'
        '  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC, anon, authenticated;',
      ),
    );
  });

  test('canonical identity helpers reject inactive profiles', () {
    final helpers = section(
      migration,
      '-- 4. Canonical identity helpers',
      '-- 5. Storage access',
    );

    for (final functionName in [
      'get_user_restaurant_id',
      'get_user_role',
      'get_user_store_id',
      'has_any_role',
      'is_super_admin',
    ]) {
      expect(
        helpers,
        contains('CREATE OR REPLACE FUNCTION public.$functionName'),
      );
    }
    expect(helpers, contains('SELECT public.get_user_restaurant_id()'));
    expect(
      RegExp(r'AND u\.is_active = TRUE').allMatches(helpers),
      hasLength(4),
    );
  });

  test('attendance QC and payment proof storage reject inactive profiles', () {
    final storage = migration.substring(
      migration.indexOf('-- 5. Storage access'),
    );

    for (final policyName in [
      'storage_attendance_scoped',
      'storage_qc_scoped',
      'storage_payment_proofs_scoped',
    ]) {
      expect(
        storage,
        contains(
          'DROP POLICY IF EXISTS $policyName ON storage.objects;\n'
          'CREATE POLICY $policyName ON storage.objects',
        ),
      );
    }
    expect(
      storage,
      contains(
        'DROP POLICY IF EXISTS authenticated_access_qc_photos '
        'ON storage.objects;',
      ),
    );
    expect(
      RegExp(r'AND u\.is_active = TRUE').allMatches(storage),
      hasLength(10),
    );
  });

  test(
    'migration is transactional replay-safe and preserves Office coupling',
    () {
      expect(migration.trimLeft(), startsWith('BEGIN;'));
      expect(migration.trimRight(), endsWith('COMMIT;'));
      expect(migration, contains('DROP POLICY IF EXISTS'));
      expect(migration, isNot(contains('DROP TABLE public.restaurants')));
      expect(migration, isNot(contains('ALTER TABLE public.restaurants')));
      expect(migration, isNot(contains('RENAME TO restaurants')));
    },
  );
}
