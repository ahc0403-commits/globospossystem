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
      'sample_count': 4,
      'kitchen_average_seconds': null,
      'tray_average_seconds': null,
      'floor_average_seconds': 42,
      'operation_average_seconds': 42,
    },
  ],
};

Widget _app({TextScaler? textScaler}) => MaterialApp(
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
        startDate: DateTime(2026, 8, 13),
        endDate: DateTime(2026, 8, 13),
        loader: _fixture,
      ),
    ),
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('shows operation, dining, and additive menu stage averages', (
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
    expect(find.text('운영 평균'), findsOne);
    expect(find.text('10분 3초'), findsWidgets);
    expect(find.text('식사 평균'), findsOne);
    expect(find.text('21분 18초'), findsOne);
    expect(find.byKey(const Key('paperless_operations_flow')), findsOne);
    expect(find.text('주방 + 트레이 + 층 서빙 = 운영 합계'), findsOne);

    await tester.ensureVisible(
      find.byKey(const Key('paperless_menu_operation_times')),
    );
    await tester.pumpAndSettle();
    expect(find.text('메뉴별 제공 시간'), findsOne);
    expect(find.text('치즈라면'), findsOne);
    expect(find.text('9분 29초'), findsOne);
    expect(find.text('아이스티'), findsOne);
    expect(find.text('—'), findsNWidgets(2));
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
    expect(find.text('운영 평균'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('refresh reloads the operations report', (tester) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var loadCount = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ko'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        theme: AppTheme.build(),
        home: Scaffold(
          body: SingleChildScrollView(
            child: PaperlessOperationsDashboard(
              storeId: _storeId,
              startDate: DateTime(2026, 8, 13),
              endDate: DateTime(2026, 8, 13),
              loader: () async {
                loadCount += 1;
                return _fixture();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(loadCount, 1);

    await tester.tap(find.byTooltip('새로고침'));
    await tester.pumpAndSettle();
    expect(loadCount, 2);
    expect(tester.takeException(), isNull);
  });
}
