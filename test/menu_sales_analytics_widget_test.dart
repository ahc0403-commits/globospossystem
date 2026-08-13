import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/report/menu_sales_analytics.dart';
import 'package:globos_pos_system/features/report/menu_sales_analytics_panel.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:intl/intl.dart';

final _params = MenuSalesAnalyticsParams(
  storeId: '00000000-0000-0000-0000-000000000001',
  startDate: DateTime(2026, 8, 13),
  endDate: DateTime(2026, 8, 13),
);

MenuSalesAnalytics _analytics() {
  final menuRows = List.generate(12, (index) {
    final rank = index + 1;
    return {
      'rank': rank,
      'menu_key': 'menu-$rank',
      'display_name': rank == 1 ? '쌀국수 스페셜' : '메뉴 $rank',
      'identity_quality': rank == 12 ? 'name_fallback' : 'stable_id',
      'name_changed_in_period': rank == 11,
      'sold_quantity': 20 - index,
      'order_count': 12 - index,
      'menu_sales_amount': rank * 100000,
      'quantity_share': 10 - index / 2,
      'revenue_share': rank,
      'peak_hour': 12 + index % 3,
      'dine_in_quantity': 10,
      'takeaway_quantity': 5,
      'delivery_quantity': 5 - index.clamp(0, 5),
    };
  });
  final hours = List.generate(24, (hour) {
    return {
      'hour': hour,
      'sold_quantity': hour >= 11 && hour <= 14 ? hour : 0,
      'menu_sales_amount': hour >= 11 && hour <= 14 ? hour * 100000 : 0,
      'order_count': hour >= 11 && hour <= 14 ? 4 : 0,
    };
  });
  final topHours = <Map<String, dynamic>>[];
  for (var rank = 1; rank <= 5; rank++) {
    for (var hour = 0; hour < 24; hour++) {
      topHours.add({
        'rank': rank,
        'menu_key': 'menu-$rank',
        'display_name': rank == 1 ? '쌀국수 스페셜' : '메뉴 $rank',
        'hour': hour,
        'sold_quantity': hour == 12 + rank % 3 ? 10 - rank : 0,
        'menu_sales_amount': hour == 12 + rank % 3 ? rank * 100000 : 0,
      });
    }
  }
  return MenuSalesAnalytics.fromJson({
    'summary': {
      'order_count': 42,
      'sold_quantity': 174,
      'sold_menu_count': 12,
      'menu_sales_amount': 7800000,
      'unallocated_adjustment_count': 1,
      'unallocated_adjustment_amount': 50000,
    },
    'menu_rows': menuRows,
    'hour_rows': hours,
    'top_menu_hour_rows': topHours,
    'scope': const {'timezone': 'Asia/Ho_Chi_Minh'},
  });
}

Widget _app({
  Future<MenuSalesAnalytics> Function()? loader,
  TextScaler? textScaler,
  bool boundedDesktopPanel = false,
}) {
  final panel = MenuSalesAnalyticsPanel(
    params: _params,
    currency: NumberFormat('#,###', 'vi_VN'),
  );
  return ProviderScope(
    overrides: [
      menuSalesAnalyticsProvider.overrideWith(
        (ref, params) => loader?.call() ?? Future.value(_analytics()),
      ),
    ],
    child: MaterialApp(
      locale: const Locale('ko'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: textScaler == null
          ? null
          : (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: child!,
            ),
      home: Scaffold(
        body: boundedDesktopPanel
            ? Center(child: SizedBox(width: 1200, height: 820, child: panel))
            : SingleChildScrollView(
                padding: const EdgeInsets.all(12),
                child: panel,
              ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final size in const [
    Size(390, 844),
    Size(768, 1024),
    Size(1024, 768),
    Size(1440, 900),
  ]) {
    testWidgets('menu sales analytics is readable at $size', (tester) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('menu_sales_top_menu')), findsOneWidget);
      expect(find.byKey(const Key('menu_sales_ranking')), findsOneWidget);
      expect(find.byKey(const Key('menu_sales_hourly')), findsOneWidget);
      expect(find.byKey(const Key('menu_sales_scope_banner')), findsOneWidget);
      expect(find.text('쌀국수 스페셜'), findsWidgets);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('ranking supports sales sorting and expanding all menus', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();

    await tester.tap(find.text('판매금액순'));
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('menu_sales_show_all')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('menu_sales_show_all')));
    await tester.pump();

    expect(find.text('메뉴 12'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('bounded desktop panel and 200% phone text do not overflow', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(_app(boundedDesktopPanel: true));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    await tester.binding.setSurfaceSize(const Size(390, 844));
    await tester.pumpWidget(_app(textScaler: TextScaler.linear(2)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menu_sales_ranking')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('empty and error states stay inside the menu panel', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final empty = MenuSalesAnalytics.fromJson({
      'summary': const {
        'order_count': 0,
        'sold_quantity': 0,
        'sold_menu_count': 0,
        'menu_sales_amount': 0,
        'unallocated_adjustment_count': 0,
        'unallocated_adjustment_amount': 0,
      },
    });
    await tester.pumpWidget(_app(loader: () async => empty));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('menu_sales_empty')), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(
      _app(loader: () => Future.error(StateError('contract error'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('메뉴 판매 현황을 불러오지 못했습니다.'), findsOneWidget);
    expect(find.text('다시 시도'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
