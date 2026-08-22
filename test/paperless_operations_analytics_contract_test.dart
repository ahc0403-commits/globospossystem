import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('paperless analytics separates menu stages and dining time', () {
    final migration = File(
      'supabase/migrations/'
      '20260822090000_paperless_menu_operation_and_dining_analytics.sql',
    ).readAsStringSync();

    expect(migration, contains('-- production-gate: self-verifying'));
    expect(migration, contains("'menu_operation_times'"));
    expect(migration, contains("'average_dining_seconds'"));
    expect(migration, contains('payment.paid_at - times.floor_served_at'));
    expect(
      migration,
      contains('events.kitchen_done_at - order_item.created_at'),
    );
    expect(
      migration,
      contains('events.tray_dispatched_at - events.kitchen_done_at'),
    );
    expect(
      migration,
      contains('events.floor_served_at - events.tray_dispatched_at'),
    );
    expect(
      migration,
      contains('events.floor_served_at - order_item.created_at'),
    );
    expect(migration, contains('scoped.order_status = \'completed\''));
    expect(migration, contains('dining_order_count'));
  });

  test('paperless dashboard labels the operational and dining definitions', () {
    final source = File(
      'lib/features/admin/widgets/paperless_operations_dashboard.dart',
    ).readAsStringSync();

    expect(source, contains("Key('paperless_operations_time_summary')"));
    expect(source, contains("Key('paperless_operations_flow')"));
    expect(source, contains("Key('paperless_menu_operation_times')"));
    expect(source, contains('주문 접수부터 모든 음식 전달까지'));
    expect(source, contains('모든 음식 제공 완료 후 결제까지'));
    expect(source, contains('주방 + 트레이 + 층 서빙 = 운영 합계'));
  });
}
