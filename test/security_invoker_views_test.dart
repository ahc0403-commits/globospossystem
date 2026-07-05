import 'dart:io';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late String fixMigration;
  late String uncommittedMigration;

  setUpAll(() {
    final fixFile = File(
      'supabase/migrations/20260610000002_security_invoker_cross_tenant_views.sql',
    );
    expect(fixFile.existsSync(), isTrue);
    fixMigration = fixFile.readAsStringSync();

    final uncommittedFile = File(
      'supabase/migrations/20260609000000_office_pos_sales_photo_objet_events.sql',
    );
    expect(uncommittedFile.existsSync(), isTrue);
    uncommittedMigration = uncommittedFile.readAsStringSync();
  });

  group('security_invoker fix migration', () {
    const expectedViews = [
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

    for (final view in expectedViews) {
      test('secures $view', () {
        expect(
          fixMigration,
          contains('$view SET (security_invoker = true)'),
          reason: '$view must have security_invoker = true',
        );
      });
    }

    test('handles v_office_pos_sales_events conditionally', () {
      expect(
        fixMigration,
        contains('v_office_pos_sales_events'),
        reason: 'Must handle Office POS sales events view',
      );
    });

    test('includes validation query as comment', () {
      expect(
        fixMigration,
        contains('pg_options_to_table'),
        reason: 'Validation query must be included for manual verification',
      );
    });
  });

  group('uncommitted migration patched', () {
    test('v_office_pos_sales_events has security_invoker', () {
      expect(
        uncommittedMigration,
        contains(
          'alter view public.v_office_pos_sales_events set (security_invoker = true)',
        ),
      );
    });

    test('v_office_pos_sales_bucket_summary has security_invoker', () {
      expect(
        uncommittedMigration,
        contains(
          'alter view public.v_office_pos_sales_bucket_summary set (security_invoker = true)',
        ),
      );
    });

    test('security_invoker comes before grants', () {
      final invokerPos = uncommittedMigration.indexOf('security_invoker');
      final grantPos =
          uncommittedMigration.indexOf('grant select on public.v_office_pos');
      expect(
        invokerPos,
        lessThan(grantPos),
        reason: 'security_invoker must be set before granting access',
      );
    });
  });
}
