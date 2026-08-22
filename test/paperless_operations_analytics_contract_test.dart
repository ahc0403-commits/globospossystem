import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('paperless analytics separates menu stages and dining time', () {
    final migration = File(
      'supabase/migrations/'
      '20260822110000_paperless_menu_operation_and_dining_analytics.sql',
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
    expect(source, contains("Key('paperless_fastest_menu_ranking')"));
    expect(source, contains("Key('paperless_slowest_menu_ranking')"));
    expect(source, contains("Key('paperless_category_operation_times')"));
    expect(source, contains("Key('paperless_operations_flow')"));
    expect(source, contains("Key('paperless_menu_operation_times')"));
    expect(source, contains('get_paperless_operations_insights_report'));
    expect(source, contains('가장 빨리 나간 메뉴 TOP 5'));
    expect(source, contains('가장 늦게 나간 메뉴 TOP 5'));
    expect(source, contains('카테고리별 평균 제공시간'));
    expect(source, contains('메뉴별 평균 제공시간'));
    expect(source, contains('주문 접수부터 모든 음식 전달까지'));
    expect(source, contains('모든 음식 제공 완료 후 결제까지'));
    expect(source, contains('주방 + 트레이 + 층 서빙 = 운영 합계'));
  });

  test('insights wrapper enriches menus and weights category averages', () {
    final migration = File(
      'supabase/migrations/20260822140000_paperless_operations_insight_dashboard.sql',
    ).readAsStringSync();

    expect(migration, contains('-- production-gate: self-verifying'));
    expect(migration, contains('get_paperless_operations_insights_report'));
    expect(migration, contains('get_paperless_operations_report'));
    expect(migration, contains("'category_operation_times'"));
    expect(migration, contains("'category_name_ko'"));
    expect(
      migration,
      contains(
        "(metric ->> 'operation_average_seconds')::numeric\n"
        "          * (metric ->> 'sample_count')::numeric",
      ),
    );
    expect(migration, contains("TO authenticated"));
    expect(migration, contains("FROM PUBLIC, anon"));
  });
}
