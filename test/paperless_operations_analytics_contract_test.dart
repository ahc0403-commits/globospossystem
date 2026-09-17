import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  const additionalOrderTimingMigration =
      'supabase/migrations/'
      '20260824050000_paperless_additional_order_timing.sql';
  const menuFloorDetailMigration =
      'supabase/migrations/'
      '20260917130000_paperless_menu_floor_timing_detail.sql';

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

  test('paperless additional orders expose independent batch timing', () {
    final migration = File(additionalOrderTimingMigration).readAsStringSync();

    expect(migration, contains('-- production-gate: self-verifying'));
    expect(migration, contains("'batch_received_at'"));
    expect(migration, contains("'kitchen_first_done_at'"));
    expect(migration, contains("'tray_first_dispatched_at'"));
    expect(migration, contains("'floor_last_served_at'"));
    expect(migration, contains('emergency_add_order_batch_timings'));
    expect(
      migration,
      contains('payment.paid_at - service.first_floor_served_at'),
    );
    expect(migration, contains('emergency_events_order_item_stage_created'));
  });

  test('paperless dashboard labels the operational and dining definitions', () {
    final source = File(
      'lib/features/admin/widgets/paperless_operations_dashboard.dart',
    ).readAsStringSync();

    expect(source, contains("Key('paperless_operations_time_summary')"));
    expect(source, contains("Key('paperless_fastest_menu_ranking')"));
    expect(source, contains('식사 중 추가 주문 대기시간도 포함합니다'));
    expect(source, contains('gồm cả thời gian chờ món gọi thêm'));
    expect(source, contains('including waits for added orders'));
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

  test(
    'menu detail preserves physical floors and established stage timing',
    () {
      final migration = File(menuFloorDetailMigration).readAsStringSync();
      final runtime = File(
        'supabase/tests/paperless_menu_timing_detail_test.sql',
      ).readAsStringSync();
      final dashboard = File(
        'lib/features/admin/widgets/paperless_operations_dashboard.dart',
      ).readAsStringSync();
      final detailSheet = File(
        'lib/features/admin/widgets/paperless_menu_timing_detail_sheet.dart',
      ).readAsStringSync();

      expect(migration, contains('-- production-gate: self-verifying'));
      expect(migration, contains('physical_floor_label'));
      expect(
        migration,
        contains('capture_emergency_queue_physical_floor_trigger'),
      );
      expect(migration, contains('get_paperless_menu_timing_detail'));
      expect(migration, contains('require_admin_actor_for_restaurant'));
      expect(migration, contains('percentile_cont(0.9)'));
      expect(migration, contains('p_after_floor_seconds'));
      expect(
        migration,
        contains('events.floor_served_at - events.tray_dispatched_at'),
      );
      expect(
        migration,
        contains('events.floor_served_at - order_item.created_at'),
      );
      expect(migration, contains('FROM PUBLIC, anon'));
      expect(migration, contains('emergency_queue_store_created_order'));

      expect(dashboard, contains('showPaperlessMenuTimingDetailSheet'));
      expect(dashboard, contains('button: true'));
      expect(dashboard, contains('Icons.chevron_right_rounded'));
      expect(detailSheet, contains("'get_paperless_menu_timing_detail'"));
      expect(detailSheet, contains("Key('paperless_menu_detail_load_more')"));
      expect(detailSheet, contains('physicalFloorLabel'));
      expect(detailSheet, contains('routingFloorLabel'));
      expect(runtime, contains('Physical floor snapshot mismatch'));
      expect(runtime, contains('Menu floor detail aggregation mismatch'));
      expect(runtime, contains('Menu floor detail cursor mismatch'));
      expect(runtime, contains('Menu floor detail filter mismatch'));
    },
  );
}
