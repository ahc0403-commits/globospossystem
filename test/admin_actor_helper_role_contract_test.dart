import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'admin actor helper allows admin-like roles and enforces accessible store scope',
    () {
      final sql = readRepoFile(
        'supabase/migrations/20260428000001_harden_admin_actor_helper_multi_access.sql',
      );

      expect(
        sql,
        contains(
          "v_actor.role NOT IN ('admin', 'store_admin', 'brand_admin', 'super_admin')",
        ),
      );
      expect(sql, contains('FROM public.user_accessible_stores(auth.uid())'));
      expect(sql, contains('WHERE s.store_id = p_restaurant_id'));
    },
  );
}
