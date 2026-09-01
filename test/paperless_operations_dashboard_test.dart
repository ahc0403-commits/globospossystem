import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/admin/widgets/paperless_operations_dashboard.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

const _storeId = '00000000-0000-0000-0000-000000000001';

Future<Map<String, dynamic>> _fixture() async => {
  'order_count': 48,
  'completed_order_count': 45,
  'dining_order_count': 40,
  'average_operation_seconds': 603,
  'average_dining_seconds': 1278,
  'bottleneck_station': 'kitchen',
  'stations': [
    {
      'station': 'kitchen',
      'sample_count': 45,
      'average_seconds': 523,
      'backlog_quantity': 0,
    },
    {
      'station': 'tray',
      'sample_count': 45,
      'average_seconds': 10,
      'backlog_quantity': 0,
    },
    {
      'station': 'floor',
      'sample_count': 45,
      'average_seconds': 70,
      'backlog_quantity': 40,
    },
  ],
  'menu_operation_times': [
    {
      'menu_key': 'menu-1',
      'name_ko': '치즈라면',
      'name_vi': 'Mì phô mai',
      'name_en': 'Cheese ramen',
      'category_name_ko': '면류',
      'category_name_vi': 'Mì',
      'category_name_en': 'Noodles',
      'sample_count': 1,
      'kitchen_average_seconds': 523,
      'tray_average_seconds': 10,
      'floor_average_seconds': 36,
      'operation_average_seconds': 569,
    },
    {
      'menu_key': 'menu-2',
      'name_ko': '돌솥 제육 비빔밥',
      'name_vi': 'Cơm trộn thịt heo',
      'name_en': 'Pork stone-pot rice',
      'category_name_ko': '밥류',
      'category_name_vi': 'Cơm',
      'category_name_en': 'Rice',
      'sample_count': 6,
      'kitchen_average_seconds': 780,
      'tray_average_seconds': 41,
      'floor_average_seconds': 161,
      'operation_average_seconds': 982,
    },
    {
      'menu_key': 'drink-1',
      'name_ko': '아이스티',
      'name_vi': 'Trà đá',
      'name_en': 'Iced tea',
      'category_name_ko': '음료',
      'category_name_vi': 'Đồ uống',
      'category_name_en': 'Drinks',
      'sample_count': 4,
      'kitchen_average_seconds': null,
      'tray_average_seconds': null,
      'floor_average_seconds': 42,
      'operation_average_seconds': 42,
    },
  ],
  'category_operation_times': [
    {
      'category_key': 'category-rice',
      'name_ko': '밥류',
      'name_vi': 'Cơm',
      'name_en': 'Rice',
      'sample_count': 6,
      'operation_average_seconds': 982,
    },
    {
      'category_key': 'category-noodles',
      'name_ko': '면류',
      'name_vi': 'Mì',
      'name_en': 'Noodles',
      'sample_count': 1,
      'operation_average_seconds': 569,
    },
    {
      'category_key': 'category-drinks',
      'name_ko': '음료',
      'name_vi': 'Đồ uống',
      'name_en': 'Drinks',
      'sample_count': 4,
      'operation_average_seconds': 42,
    },
  ],
};

Widget _app({
  TextScaler? textScaler,
  DateTime? startDate,
  DateTime? endDate,
  PaperlessOperationsLoader? loader,
}) => MaterialApp(
  locale: const Locale('ko'),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: AppTheme.build(),
  builder: textScaler == null
      ? null
      : (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: textScaler),
          child: child!,
        ),
  home: Scaffold(
    appBar: AppBar(title: const Text('페이퍼리스 운영 분석')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: PaperlessOperationsDashboard(
        storeId: _storeId,
        startDate: startDate ?? DateTime(2026, 8, 13),
        endDate: endDate ?? DateTime(2026, 8, 13),
        loader: loader ?? _fixture,
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows rankings, category averages, and menu stage averages', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('paperless_operations_time_summary')),
      findsOne,
    );
    expect(find.text('평균 제공시간'), findsOne);
    expect(find.text('10분 3초'), findsWidgets);
    expect(find.text('식사 평균'), findsOne);
    expect(find.text('21분 18초'), findsOne);
    final serviceSummary = tester.getRect(
      find.byKey(const Key('paperless_summary_service_time')),
    );
    final diningSummary = tester.getRect(
      find.byKey(const Key('paperless_summary_dining_time')),
    );
    expect((serviceSummary.top - diningSummary.top).abs(), lessThan(1));
    expect(diningSummary.left, greaterThan(serviceSummary.left));
    expect(find.byKey(const Key('paperless_fastest_menu_ranking')), findsOne);
    expect(find.byKey(const Key('paperless_slowest_menu_ranking')), findsOne);
    expect(find.text('가장 빨리 나간 메뉴 TOP 5'), findsOne);
    expect(find.text('가장 늦게 나간 메뉴 TOP 5'), findsOne);
    expect(
      find.byKey(const Key('paperless_category_operation_times')),
      findsOne,
    );
    expect(find.text('카테고리별 평균 제공시간'), findsOne);
    expect(find.text('밥류'), findsWidgets);
    expect(find.byKey(const Key('paperless_operations_flow')), findsOne);
    expect(find.text('주방 + 트레이 + 층 서빙 = 운영 합계'), findsOne);

    await tester.ensureVisible(
      find.byKey(const Key('paperless_menu_operation_times')),
    );
    await tester.pumpAndSettle();
    expect(find.text('메뉴별 평균 제공시간'), findsOne);
    expect(find.text('느린 순 · 막대 길이는 전체 제공시간, 색상은 구간별 평균'), findsOne);
    expect(find.text('치즈라면'), findsWidgets);
    expect(find.text('9분 29초'), findsWidgets);
    expect(find.text('아이스티'), findsWidgets);
    expect(find.textContaining('—'), findsNWidgets(2));
    expect(tester.takeException(), isNull);
  });

  testWidgets('desktop places fastest and slowest rankings side by side', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 1100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    final fastest = tester.getRect(
      find.byKey(const Key('paperless_fastest_menu_ranking')),
    );
    final slowest = tester.getRect(
      find.byKey(const Key('paperless_slowest_menu_ranking')),
    );
    expect((fastest.top - slowest.top).abs(), lessThan(1));
    expect(slowest.left, greaterThan(fastest.right));

    final categoryFirst = tester.getRect(
      find.byKey(const Key('paperless_category_timing_category-rice')),
    );
    final categorySecond = tester.getRect(
      find.byKey(const Key('paperless_category_timing_category-noodles')),
    );
    expect((categoryFirst.top - categorySecond.top).abs(), lessThan(1));
    expect(categorySecond.left, greaterThan(categoryFirst.right));

    final menuFirst = tester.getRect(
      find.byKey(const Key('paperless_menu_timing_menu-2')),
    );
    final menuSecond = tester.getRect(
      find.byKey(const Key('paperless_menu_timing_menu-1')),
    );
    expect((menuFirst.top - menuSecond.top).abs(), lessThan(1));
    expect(menuSecond.left, greaterThan(menuFirst.right));

    final slowestBar = tester.getSize(
      find.byKey(const Key('paperless_menu_bar_fill_menu-2')),
    );
    final fasterBar = tester.getSize(
      find.byKey(const Key('paperless_menu_bar_fill_menu-1')),
    );
    expect(slowestBar.width, greaterThan(fasterBar.width));
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone layout remains readable at 200 percent text scale', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(textScaler: TextScaler.linear(2)));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('paperless_operations_dashboard')), findsOne);
    expect(find.text('평균 제공시간'), findsOne);

    final serviceSummary = tester.getRect(
      find.byKey(const Key('paperless_summary_service_time')),
    );
    final diningSummary = tester.getRect(
      find.byKey(const Key('paperless_summary_dining_time')),
    );
    expect(diningSummary.top, greaterThan(serviceSummary.bottom));

    final categoryFirst = tester.getRect(
      find.byKey(const Key('paperless_category_timing_category-rice')),
    );
    final categorySecond = tester.getRect(
      find.byKey(const Key('paperless_category_timing_category-noodles')),
    );
    expect(categorySecond.top, greaterThan(categoryFirst.bottom));
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh reloads the operations report', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var loadCount = 0;
    await tester.pumpWidget(
      _app(
        loader: () async {
          loadCount += 1;
          return _fixture();
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(loadCount, 1);

    await tester.tap(find.byTooltip('새로고침'));
    await tester.pumpAndSettle();
    expect(loadCount, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single date selection applies the chosen day and reloads', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var loadCount = 0;
    await tester.pumpWidget(
      _app(
        loader: () async {
          loadCount += 1;
          return _fixture();
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(loadCount, 1);

    await tester.tap(find.byKey(const Key('paperless_select_single_date')));
    await tester.pumpAndSettle();
    expect(find.byType(DatePickerDialog), findsOne);

    await tester.tap(find.text('12'));
    await tester.tap(find.text('확인'));
    await tester.pumpAndSettle();

    expect(find.text('2026.08.12'), findsOne);
    expect(loadCount, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('date range selection applies both dates and reloads', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(900, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var loadCount = 0;
    await tester.pumpWidget(
      _app(
        loader: () async {
          loadCount += 1;
          return _fixture();
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(loadCount, 1);

    await tester.tap(find.byKey(const Key('paperless_select_date_range')));
    await tester.pumpAndSettle();

    expect(find.byType(DateRangePickerDialog), findsOne);
    final dialogContext = tester.element(find.byType(DateRangePickerDialog));
    final saveLabel = MaterialLocalizations.of(dialogContext).saveButtonLabel;
    await tester.tap(find.text('10').first);
    await tester.pump();
    await tester.tap(find.text('12').first);
    await tester.pump();
    await tester.tap(find.text(saveLabel));
    await tester.pumpAndSettle();

    expect(find.text('2026.08.10 – 2026.08.12'), findsOne);
    expect(loadCount, 2);
    expect(tester.takeException(), isNull);
  });
}
