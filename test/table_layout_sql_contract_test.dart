import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test(
    'table floor layout migration adds normalized layout fields and RPC support',
    () {
      final migration = readRepoFile(
        'supabase/migrations/20260502000000_table_floor_layout.sql',
      );

      expect(migration, contains('layout_x NUMERIC(6,4)'));
      expect(migration, contains('layout_y NUMERIC(6,4)'));
      expect(migration, contains('layout_w NUMERIC(6,4)'));
      expect(migration, contains('layout_h NUMERIC(6,4)'));
      expect(migration, contains('layout_rotation INT'));
      expect(migration, contains('layout_shape TEXT'));
      expect(migration, contains('layout_sort_order INT'));
      expect(migration, contains('CHECK (layout_shape IN'));
      expect(migration, contains('p_layout_x NUMERIC DEFAULT NULL'));
      expect(migration, contains('p_layout_y NUMERIC DEFAULT NULL'));
      expect(migration, contains('admin_create_table'));
      expect(migration, contains('v_next_sort_order'));
      expect(migration, contains('v_next_x'));
      expect(migration, contains('v_next_y'));
      expect(migration, contains('admin_update_table'));
      expect(migration, contains("'layout_x'"));
      expect(migration, contains("'layout_y'"));
    },
  );

  test('table mutation RPCs require explicit store boundary', () {
    final migration = readRepoFile(
      'supabase/migrations/20260509000000_audit_findings_rpc_boundaries.sql',
    );
    final service = readRepoFile('lib/core/services/tables_service.dart');

    expect(
      migration,
      contains('CREATE OR REPLACE FUNCTION public.admin_update_table'),
    );
    expect(migration, contains('p_store_id UUID'));
    expect(migration, contains('TABLE_STORE_MISMATCH'));
    expect(
      migration,
      contains('PERFORM public.require_admin_actor_for_restaurant(p_store_id)'),
    );
    expect(
      migration,
      contains('CREATE OR REPLACE FUNCTION public.admin_delete_table'),
    );
    expect(service, contains("'p_store_id': storeId"));
  });
}
