import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'audit log reads stay available to admin-like report roles with store scoping',
    () {
      final migration = readRepoFile(
        'supabase/migrations/20260425000001_harden_audit_logs_scope_for_reports.sql',
      );
      final reportsTab = readRepoFile(
        'lib/features/admin/tabs/reports_tab.dart',
      );
      final roleRoutes = readRepoFile('lib/core/utils/role_routes.dart');

      expect(migration, contains('CREATE POLICY audit_logs_admin_read'));
      expect(migration, contains("'store_admin'"));
      expect(migration, contains("'brand_admin'"));
      expect(migration, contains('public.user_accessible_stores(auth.uid())'));
      expect(migration, contains("NULLIF(details ->> 'store_id', '')::uuid"));
      expect(
        migration,
        contains("NULLIF(details ->> 'restaurant_id', '')::uuid"),
      );
      expect(reportsTab, contains('ReportsTab'));
      expect(roleRoutes, contains("'brand_admin' ||"));
      expect(roleRoutes, contains("'store_admin' ||"));
    },
  );
}
