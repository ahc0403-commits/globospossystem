import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('POS store creation links a pending Office store identity', () {
    final migration = readRepoFile(
      'supabase/migrations/20260518010000_office_pending_store_link_on_pos_create.sql',
    );

    expect(migration, contains('ALTER TABLE ops.stores'));
    expect(migration, contains('pos_store_id uuid'));
    expect(migration, contains('DEFERRABLE INITIALLY DEFERRED'));
    expect(migration, contains('idx_ops_stores_pos_store_id'));
    expect(migration, contains('v_new_store_id uuid := gen_random_uuid()'));
    expect(
      migration,
      contains('public.link_office_pending_store_for_pos_store'),
    );
    expect(migration, contains("status = 'pending'::core.account_status"));
    expect(migration, contains('p_office_store_id uuid DEFAULT NULL'));
    expect(migration, contains('RESTAURANT_BRAND_REQUIRED'));
    expect(migration, contains("'office_store_status'"));
  });

  test('super admin add store requires a brand before create/update', () {
    final screen = readRepoFile(
      'lib/features/super_admin/super_admin_screen.dart',
    );

    expect(screen, contains('l10n.superAdminBrandRequiredBeforeStore'));
    expect(screen, contains('final brandId = selectedBrandId!;'));
    expect(screen, isNot(contains("child: Text('Uncategorized')")));
  });
}
