import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('floor-direct beverage ledger is additive and route-gated', () {
    final schema = File(
      'supabase/migrations/20260812150000_floor_direct_beverage_fulfillment.sql',
    ).readAsStringSync();
    final runtime = File(
      'supabase/migrations/20260812151000_floor_direct_beverage_runtime.sql',
    ).readAsStringSync();
    final actions = File(
      'supabase/migrations/20260812152000_floor_direct_beverage_actions.sql',
    ).readAsStringSync();

    expect(schema, contains('emergency_floor_direct_items'));
    expect(schema, contains('floor_direct_beverages_enabled'));
    expect(schema, contains('fulfillment_route_snapshot'));
    expect(runtime, contains("'floor_direct_ready'"));
    expect(runtime, contains("'floor'"));
    expect(actions, contains('emergency_record_floor_direct_progress'));
    expect(actions, contains("v_assignment.station_type <> 'floor'"));
  });

  test('read surfaces and analytics union standard and direct lines', () {
    final reads = File(
      'supabase/migrations/20260812153000_floor_direct_beverage_reads.sql',
    ).readAsStringSync();
    final qr = File(
      'supabase/migrations/20260812154000_qr_floor_direct_delivery_progress.sql',
    ).readAsStringSync();
    final analytics = File(
      'supabase/migrations/20260812156000_paperless_operations_analytics.sql',
    ).readAsStringSync();

    expect(reads, contains('get_emergency_order_item_progress'));
    expect(reads, contains("'fulfillment_route', 'floor_direct'"));
    expect(qr, contains("'fulfillment_parts'"));
    expect(analytics, contains('get_paperless_operations_report'));
    expect(analytics, contains("'bottleneck_station'"));
    expect(analytics, contains('percentile_cont(0.9)'));
  });
}
