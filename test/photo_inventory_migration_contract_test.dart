import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('PHOTO simple inventory RPC enforces role, scope, and brand', () {
    final sql = File(
      'supabase/migrations/'
      '20260723081529_photo_objet_simple_inventory_management.sql',
    ).readAsStringSync();

    expect(sql, contains('upsert_photo_objet_inventory_item'));
    expect(
      sql,
      contains("v_actor.role NOT IN ('photo_objet_master', 'super_admin')"),
    );
    expect(sql, contains('require_admin_actor_for_restaurant(p_store_id)'));
    expect(sql, contains("'77000000-0000-0000-0000-000000000001'::uuid"));
    expect(sql, contains('PHOTO_INVENTORY_NAME_DUPLICATE'));
    expect(sql, contains('photo_inventory_item_created'));
    expect(sql, contains('photo_inventory_item_updated'));
    expect(sql, contains('FROM PUBLIC, anon'));
    expect(sql, contains('TO authenticated'));
  });

  test('PHOTO simple inventory migration has production deployment gates', () {
    final deployScript = File(
      'scripts/deploy_pos_production.sh',
    ).readAsStringSync();
    final preflight = File(
      'scripts/preflight_photo_objet_simple_inventory_management.sql',
    ).readAsStringSync();
    final verification = File(
      'scripts/verify_photo_objet_simple_inventory_management.sql',
    ).readAsStringSync();

    expect(
      deployScript,
      contains('20260723081529_photo_objet_simple_inventory_management.sql'),
    );
    expect(
      deployScript,
      contains('preflight_photo_objet_simple_inventory_management.sql'),
    );
    expect(
      deployScript,
      contains('verify_photo_objet_simple_inventory_management.sql'),
    );
    expect(preflight, contains('require_admin_actor_for_restaurant(uuid)'));
    expect(verification, contains('prosecdef'));
    expect(verification, contains('search_path=public, auth, pg_catalog'));
    expect(verification, contains("'anon'"));
    expect(verification, contains("'authenticated'"));
  });
}
