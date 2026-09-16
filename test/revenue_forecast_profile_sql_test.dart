import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  final sql = File(
    'supabase/migrations/20260916100000_revenue_forecast_profiles.sql',
  ).readAsStringSync();

  test('forecast profiles are additive, versioned, and store scoped', () {
    expect(sql, contains('revenue_forecast_profile_versions'));
    expect(sql, contains('UNIQUE (restaurant_id, revision)'));
    expect(sql, contains('WHERE effective_to IS NULL'));
    expect(sql, contains('user_accessible_stores'));
    expect(sql, contains('FORECAST_PROFILE_CONFLICT'));
    expect(sql, isNot(contains('ALTER TABLE public.restaurants RENAME')));
  });

  test('profile writes match BM and platform owner roles', () {
    expect(sql, contains("'brand_admin', 'photo_objet_master', 'super_admin'"));
    expect(sql, contains('FORECAST_PROFILE_WRITE_FORBIDDEN'));
    expect(sql, contains('scope.store_id = p_store_id'));
    expect(sql, isNot(contains("'admin', 'store_admin', 'brand_admin'")));
  });

  test('profile reads are limited to BM and platform owner roles', () {
    expect(sql, contains('FORECAST_READ_FORBIDDEN'));
    expect(
      RegExp(
        r"actor\.role IN \('brand_admin', 'photo_objet_master', 'super_admin'\)",
      ).allMatches(sql).length,
      greaterThanOrEqualTo(2),
    );
  });

  test('Photo constants cannot be overridden by profile JSON', () {
    expect(sql, contains("p_model_type NOT IN ('restaurant', 'photo')"));
    expect(sql, contains("/ 8"));
    expect(sql, isNot(contains("p_settings->>'session_minutes'")));
    expect(sql, isNot(contains("p_settings->>'revenue_per_session_vnd'")));
  });

  test('operating weekdays are required, bounded, and unique', () {
    expect(sql, contains("p_settings ? 'operating_weekdays'"));
    expect(sql, contains("weekday.value::text !~ '^[1-7]\$'"));
    expect(sql, contains('count(DISTINCT weekday.value)'));
    expect(sql, contains('FORECAST_OPERATING_WEEKDAYS_INVALID'));
  });

  test('clients cannot write profile history directly', () {
    expect(
      sql,
      contains(
        'REVOKE ALL ON public.revenue_forecast_profile_versions FROM anon, authenticated',
      ),
    );
    expect(
      sql,
      contains(
        'GRANT SELECT ON public.revenue_forecast_profile_versions TO authenticated',
      ),
    );
  });

  test('store brand and forecast model type cannot be mixed', () {
    expect(sql, contains("77000000-0000-0000-0000-000000000001'::uuid"));
    expect(sql, contains('FORECAST_MODEL_STORE_MISMATCH'));
    expect(sql, contains("<> (p_model_type = 'photo')"));
  });
}
