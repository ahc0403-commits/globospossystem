import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const bridgeMigrationPath =
    'supabase/migrations/'
    '20260909100000_pos_finance_uat_bridge_contract.sql';
const parityMigrationPath =
    'supabase/migrations/'
    '20260909140000_sample_inventory_purchase_pilot_parity.sql';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('SAMPLE is exposed only through the exact Office pilot identity', () {
    final bridge = readRepoFile(bridgeMigrationPath);

    expect(bridge, contains('-- production-gate: self-verifying'));
    expect(bridge, contains('BunsikClub SAMPLE'));
    expect(bridge, contains('3a268807-771f-4fd4-84fe-e1b0b00de40a'));
    expect(bridge, contains('a3bbff2e-a6f7-4c19-b2bd-410ec9a4f878'));
    expect(bridge, contains('8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1'));
    expect(bridge, contains('PENDING_SAMPLE_STORE_TAX_PROFILE'));
    expect(bridge, contains('WITH (security_invoker = true)'));
    expect(
      bridge,
      contains(
        'REVOKE ALL ON public.v_office_confirmed_inventory_purchase_receipts\n'
        '  FROM PUBLIC, anon, authenticated;',
      ),
    );
    expect(bridge, contains('TO service_role;'));
  });

  test(
    'production SAMPLE mirrors purchase master data without sharing stock',
    () {
      final migration = readRepoFile(parityMigrationPath);

      expect(migration, contains('-- production-gate: self-verifying'));
      expect(migration, contains('BunsikClub Binh Thanh'));
      expect(migration, contains('BunsikClub SAMPLE'));
      expect(migration, contains('8bc9eef5-dcd5-46b1-b931-23f77132322c'));
      expect(migration, contains('3a268807-771f-4fd4-84fe-e1b0b00de40a'));
      expect(migration, contains('INSERT INTO public.inventory_items'));
      expect(migration, contains('INSERT INTO public.inventory_products'));
      expect(
        migration,
        contains('INSERT INTO public.inventory_supplier_items'),
      );
      expect(migration, contains("'sample-pilot-inventory-item:'"));
      expect(migration, contains("'sample-pilot-product:'"));
      expect(migration, contains("'sample-pilot-supplier-item:'"));
      expect(migration, contains('source_item.reorder_point'));
      expect(migration, contains('source_item.cost_per_unit'));
      expect(migration, contains('    0,\n    source_item.unit,\n    0,'));
      expect(migration, isNot(contains('source_item.current_stock')));
      expect(migration, isNot(contains('source_item.quantity')));
    },
  );

  test('production SAMPLE keeps distinct purchase pilot actors', () {
    final migration = readRepoFile(parityMigrationPath);

    for (final actor in ['sp_order', 'bunsik_sm2', 'bunsik_bm1', 'account']) {
      expect(migration, contains("fixed_account_code = '$actor'"));
    }
    for (final role in [
      'inventory_orderer',
      'store_admin',
      'brand_admin',
      'inventory_accounting',
    ]) {
      expect(migration, contains("actor.role = '$role'"));
    }
    expect(migration, contains('public.user_tax_entity_access'));
    expect(migration, contains('public.user_accessible_stores'));
    expect(
      migration,
      contains('SAMPLE_PURCHASE_PILOT_ACCOUNTING_SCOPE_FAILED'),
    );
    expect(
      migration,
      contains('SAMPLE_PURCHASE_PILOT_OFFICE_BRIDGE_NOT_READY'),
    );
    expect(migration, isNot(contains('UPDATE public.users SET role')));
  });
}
