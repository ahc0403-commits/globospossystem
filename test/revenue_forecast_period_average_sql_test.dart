import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const migrationPath =
      'supabase/migrations/20260916160000_revenue_forecast_period_averages.sql';

  test('forecast average RPC is additive, authorized, and assumption free', () {
    final sql = File(migrationPath).readAsStringSync();
    final functionBody = sql.split('REVOKE ALL').first;

    expect(sql, contains('-- production-gate: self-verifying'));
    expect(sql, contains('get_revenue_forecast_operating_averages'));
    expect(sql, contains('get_paperless_operations_insights_report'));
    expect(sql, contains("order_row.status <> 'cancelled'"));
    expect(sql, contains('item.is_cancelled = false'));
    expect(sql, contains('state.floor_complete'));
    expect(sql, contains("event.stage = 'floor_served'"));
    expect(sql, contains('event.delta > 0'));
    expect(sql, contains('avg(first_serve_seconds)'));
    expect(sql, contains('forecast_hourly_orders'));
    expect(sql, contains('TO authenticated'));
    expect(sql, contains('FROM PUBLIC, anon'));
    expect(functionBody, isNot(contains('250000')));
    expect(functionBody, isNot(contains('1.15')));
  });
}
