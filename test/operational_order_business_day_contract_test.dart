import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

const _migrationPath =
    'supabase/migrations/20260901130000_operational_order_business_day_scope.sql';

void main() {
  test('database scopes every operational order list to the Vietnam day', () {
    final sql = File(_migrationPath).readAsStringSync();

    for (final functionName in [
      'get_emergency_station_snapshot_base',
      'get_emergency_station_timings',
      'get_kds_ticket_v2',
      'search_active_order_for_cashier',
      'direct_order_staff_list',
      'direct_delivery_ticket_list',
    ]) {
      expect(
        sql,
        contains('FUNCTION public.$functionName'),
        reason: '$functionName must be covered',
      );
    }

    expect(
      RegExp("AT TIME ZONE 'Asia/Ho_Chi_Minh'").allMatches(sql).length,
      greaterThanOrEqualTo(7),
    );
    expect(sql, contains('queue.created_at >= v_day_start'));
    expect(sql, contains('queue.created_at < v_day_end'));
    expect(sql, contains('order_row.created_at >= v_day_start'));
    expect(sql, contains('request_row.created_at >= v_day_start'));
    expect(sql, contains('ticket.created_at >= v_day_start'));
    expect(sql, contains('emergency_queue_session_created_queue'));
    expect(sql, contains('orders_store_status_created_id'));
  });

  test('Flutter cashier and kitchen use the same exclusive UTC window', () {
    final timeUtils = File('lib/core/utils/time_utils.dart').readAsStringSync();
    final cashier = File(
      'lib/features/payment/payment_provider.dart',
    ).readAsStringSync();
    final kitchen = File(
      'lib/features/kitchen/kitchen_provider.dart',
    ).readAsStringSync();

    expect(timeUtils, contains('currentVietnamBusinessDay'));
    expect(timeUtils, contains('Asia/Ho_Chi_Minh'));
    for (final source in [cashier, kitchen]) {
      expect(source, contains(".gte('created_at', businessDay.startIso8601)"));
      expect(source, contains(".lt('created_at', businessDay.endIso8601)"));
      expect(source, contains('_scheduleBusinessDayRefresh'));
      expect(source, contains('businessDay.refreshDelay'));
    }
    expect(
      cashier,
      isNot(contains(".gte('updated_at', todayStart)")),
      reason: 'completed cashier history is scoped by order creation day',
    );
  });

  test('KDS distinguishes a failed lookup from a real unassigned account', () {
    final provider = File(
      'lib/features/emergency_fulfillment/emergency_fulfillment_provider.dart',
    ).readAsStringSync();
    final screen = File(
      'lib/features/emergency_fulfillment/emergency_fulfillment_screen.dart',
    ).readAsStringSync();

    expect(provider, contains('assignmentResolved'));
    expect(provider, contains('_scheduleSnapshotRetry'));
    expect(provider, contains('EMERGENCY_ASSIGNMENT_RESPONSE_INVALID'));
    expect(screen, contains('assignmentLoadFailed'));
    expect(screen, contains('orderLoadRetrying'));
    expect(screen, contains('state.stationType ?? expected'));
  });
}
