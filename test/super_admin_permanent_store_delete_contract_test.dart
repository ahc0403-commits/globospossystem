import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';

SuperRestaurant _store(String id, {required bool isActive}) {
  return SuperRestaurant(
    id: id,
    name: id,
    slug: id,
    address: '',
    operationMode: 'standard',
    perPersonCharge: null,
    isActive: isActive,
    createdAt: DateTime(2026, 7, 19),
    ownerType: 'internal',
  );
}

String _read(String path) => File(path).readAsStringSync();

void main() {
  test('active stores are the default and inactive stores are explicit', () {
    final initial = SuperAdminState(
      restaurants: [
        _store('active', isActive: true),
        _store('inactive', isActive: false),
      ],
      reportStart: DateTime(2026, 7, 1),
      reportEnd: DateTime(2026, 7, 19),
    );

    expect(initial.selectedActivity, 'active');
    expect(initial.filteredRestaurants.map((store) => store.id), ['active']);
    expect(
      initial
          .copyWith(selectedActivity: 'inactive')
          .filteredRestaurants
          .map((store) => store.id),
      ['inactive'],
    );
    expect(
      initial
          .copyWith(selectedActivity: 'all')
          .filteredRestaurants
          .map((store) => store.id),
      ['active', 'inactive'],
    );
  });

  test('permanent deletion is guarded in DB, UI, and deployment', () {
    final migration = _read(
      'supabase/migrations/20260719030000_admin_permanent_store_delete.sql',
    );
    final screen = _read('lib/features/super_admin/super_admin_screen.dart');
    final deploy = _read('scripts/deploy_pos_production.sh');

    expect(migration, contains('STORE_PURGE_REQUIRES_INACTIVE'));
    expect(migration, contains('STORE_PURGE_CONFIRMATION_MISMATCH'));
    expect(migration, contains('STORE_PURGE_HAS_ACCOUNTS'));
    expect(migration, contains('IF NOT public.is_super_admin()'));
    expect(migration, isNot(contains('office_purchases')));
    expect(migration, isNot(contains('office_qc_followups')));
    expect(
      migration,
      contains('REVOKE ALL ON FUNCTION public._purge_inactive_store_data'),
    );
    expect(screen, contains("Key('super_admin_purge_store_button')"));
    expect(screen, contains("Key('super_admin_purge_store_slug')"));
    expect(deploy, contains('preflight_admin_permanent_store_delete.sql'));
    expect(deploy, contains('verify_admin_permanent_store_delete.sql'));
    expect(deploy, contains('rollback_admin_permanent_store_delete.sql'));
  });
}
