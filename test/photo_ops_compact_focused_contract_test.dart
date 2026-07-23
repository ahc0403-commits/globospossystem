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

  test('latest Photo Ops sales are loaded through the scoped server RPC', () {
    final service = File(
      'lib/features/photo_ops/photo_ops_service.dart',
    ).readAsStringSync();
    final migration = File(
      'supabase/migrations/20260723060000_photo_ops_latest_sales_rpc.sql',
    ).readAsStringSync();

    expect(service, contains("rpc('get_photo_ops_latest_sales')"));
    expect(migration, contains('max(s.sale_date)'));
    expect(migration, contains('public.user_accessible_stores(auth.uid())'));
    expect(migration, contains("'photo_objet_master'"));
    expect(migration, contains('FROM PUBLIC, anon'));
  });

  test('production deployment gates the latest-sales RPC migration', () {
    final deploy = File('scripts/deploy_pos_production.sh').readAsStringSync();

    expect(deploy, contains('20260723060000_photo_ops_latest_sales_rpc.sql'));
    expect(deploy, contains('preflight_photo_ops_latest_sales_rpc.sql'));
    expect(deploy, contains('verify_photo_ops_latest_sales_rpc.sql'));
  });
}
