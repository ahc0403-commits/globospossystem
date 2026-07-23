import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('Photo Ops uses a compact context and focused menu content', () {
    final screen = File(
      'lib/features/photo_ops/photo_ops_screen.dart',
    ).readAsStringSync();

    expect(screen, contains("Key('photo_ops_compact_context')"));
    expect(screen, contains('showHeader: false'));
    expect(screen, contains('_selectSurface(index, notifier.load)'));
    expect(screen, isNot(contains('_HeroBanner(')));
    expect(screen, isNot(contains('class _HeroBanner')));
    expect(screen, isNot(contains('class _MetaPill')));
    expect(
      screen,
      isNot(
        contains(
          '_StoreScopeList(stores: stores, activeStoreId: activeStoreId)',
        ),
      ),
    );
  });

  test('Photo Ops sales are loaded through the scoped range RPC', () {
    final service = File(
      'lib/features/photo_ops/photo_ops_service.dart',
    ).readAsStringSync();
    final migration = File(
      'supabase/migrations/20260723070000_photo_ops_inventory_cleanup_sales_range.sql',
    ).readAsStringSync();

    expect(service, contains("'get_photo_ops_sales_range'"));
    expect(service, contains("'p_start_date':"));
    expect(service, contains("'p_end_date':"));
    expect(
      migration,
      contains('s.sale_date BETWEEN p_start_date AND p_end_date'),
    );
    expect(migration, contains('public.user_accessible_stores(auth.uid())'));
    expect(migration, contains("'photo_objet_master'"));
    expect(migration, contains('FROM PUBLIC, anon'));
  });

  test('production deployment gates inventory cleanup and sales range', () {
    final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();

    expect(
      deploy,
      contains('20260723070000_photo_ops_inventory_cleanup_sales_range.sql'),
    );
    expect(
      deploy,
      contains('preflight_photo_ops_inventory_cleanup_sales_range.sql'),
    );
    expect(
      deploy,
      contains('verify_photo_ops_inventory_cleanup_sales_range.sql'),
    );
  });
}
