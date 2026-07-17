import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  const migration =
      'supabase/migrations/20260716210000_restaurant_sales_excel_export.sql';
  const screen =
      'lib/features/restaurant_sales_export/restaurant_sales_export_screen.dart';
  const router = 'lib/core/router/app_router.dart';
  const deploy = 'scripts/deploy_pos_production.sh';

  test('export RPC is finalized-only, read-only, and super-admin-only', () {
    final sql = readRepoFile(migration);

    expect(sql, contains('get_restaurant_daily_sales_export'));
    expect(sql, contains('public.is_super_admin()'));
    expect(sql, contains('RESTAURANT_SALES_EXPORT_FORBIDDEN'));
    expect(sql, contains('restaurant_daily_sales_finalizations'));
    expect(sql, contains('v_restaurant_sales_receipts'));
    expect(sql, contains("'pending'"));
    expect(sql, contains("v_finalization.status = 'finalized'"));
    expect(sql, contains('REVOKE ALL'));
    expect(sql, contains('TO authenticated'));
    expect(sql, isNot(contains('customer_name')));
    expect(sql, isNot(contains('customer_email')));
    expect(sql, isNot(contains('INSERT INTO public.restaurant_daily')));
    expect(sql, isNot(contains('UPDATE public.restaurant_daily')));
  });

  test('Windows automation has a stable protected download route', () {
    final routerSource = readRepoFile(router);
    final screenSource = readRepoFile(screen);

    expect(routerSource, contains("path: '/restaurant-sales-export'"));
    expect(routerSource, contains("location == '/restaurant-sales-export'"));
    expect(screenSource, contains('restaurant_sales_export_button'));
    expect(screenSource, contains('restaurant_sales_'));
    expect(screenSource, contains("ext: 'xlsx'"));
    expect(screenSource, contains('restaurantHcmBusinessDate'));
  });

  test('production runner has explicit preflight and verification gates', () {
    final deployment = readRepoFile(deploy);

    expect(
      deployment,
      contains('20260716210000_restaurant_sales_excel_export.sql'),
    );
    expect(deployment, contains('preflight_restaurant_sales_excel_export.sql'));
    expect(deployment, contains('verify_restaurant_sales_excel_export.sql'));
  });
}
