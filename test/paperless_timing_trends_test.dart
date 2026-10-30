import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:excel/excel.dart' hide Border;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/admin/widgets/paperless_operations_dashboard.dart';
import 'package:globos_pos_system/features/admin/widgets/paperless_timing_trends.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

Map<String, dynamic> _menu(
  String key,
  String name,
  int baseline,
  int current, {
  int count = 12,
}) => {
  'menu_key': key,
  'name_ko': name,
  'name_en': '$name menu',
  'name_vi': '$name món',
  'baseline_average_seconds': baseline,
  'baseline_sample_count': count,
  'current_average_seconds': current,
  'current_sample_count': count,
  'points': [
    for (var i = 0; i < 8; i++)
      if (i != 5)
        {
          'bucket_index': i,
          'average_seconds': baseline + (current - baseline) * (i + 1) ~/ 8,
          'sample_count': count,
        },
  ],
};

Map<String, dynamic> _fixture() => {
  'baseline_from': '2026-09-23',
  'baseline_to': '2026-09-30',
  'buckets': [
    for (var i = 0; i < 8; i++)
      {
        'index': i,
        'from_date': '2026-10-0${i + 1}',
        'to_date': '2026-10-0${i + 1}',
      },
  ],
  'menus': [
    _menu('faster', '김치찌개', 900, 600),
    _menu('slower', '돈가스', 840, 1140),
    _menu('stable', '제육볶음', 720, 730),
    _menu('small', '치즈라면', 600, 1200, count: 2),
    {
      ..._menu('new', '신메뉴', 0, 300),
      'baseline_average_seconds': null,
      'baseline_sample_count': 0,
    },
  ],
};

Widget _app({
  Locale locale = const Locale('ko'),
  double textScale = 1,
  Map<String, dynamic>? fixture,
  Widget? child,
}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  theme: AppTheme.build(),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child:
          child ??
          PaperlessTimingTrendsSection(
            trends: PaperlessTimingTrends.fromJson(fixture ?? _fixture()),
          ),
    ),
  ),
);

void main() {
  test('classifies comparable means, small samples and missing baselines', () {
    final trends = PaperlessTimingTrends.fromJson(_fixture());
    expect(trends.menus.map((m) => m.change), [
      PaperlessTimingChange.improved,
      PaperlessTimingChange.worsened,
      PaperlessTimingChange.stable,
      PaperlessTimingChange.insufficient,
      PaperlessTimingChange.insufficient,
    ]);
    expect(trends.menus.first.deltaSeconds, -300);
    expect(trends.menus.last.deltaSeconds, isNull);
    expect(trends.menus.first.points[5], isNull);
    expect(trends.buckets.first.label, '10/01');
  });

  test('Excel preserves baseline, changes and missing bucket values', () {
    final bytes = buildPaperlessOperationsWorkbook(
      rawReport: {'order_count': 1},
      rawTimingTrends: _fixture(),
      startDate: DateTime(2026, 10, 1),
      endDate: DateTime(2026, 10, 8),
      languageCode: 'ko',
    );
    final excel = Excel.decodeBytes(bytes);
    final comparison = excel.tables['Timing Comparison']!;
    expect(comparison.rows[2][6]!.value, const IntCellValue(-300));
    final history = excel.tables['Timing Trends']!;
    // The sixth daily bucket is missing; do not invent a zero-second time.
    expect(history.rows[6][4]!.value, const IntCellValue(0));
    expect(history.rows[6][5]?.value.toString(), '');
    expect(history.rows[6][6]?.value.toString(), '');
  });

  for (final locale in const [Locale('ko'), Locale('en'), Locale('vi')]) {
    for (final width in [390.0, 768.0, 1440.0]) {
      testWidgets('trends ${locale.languageCode} ${width}px at 200% text', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(_app(locale: locale, textScale: 2));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final menu = find.byKey(const Key('paperless_trend_menu_slower'));
        await tester.ensureVisible(menu);
        await tester.tap(menu);
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('paperless_trend_detail_slower')),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
      });
    }
  }

  testWidgets(
    'defaults to slowdowns, filters improvements and sorts by samples',
    (tester) async {
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(
        tester
            .getTopLeft(find.byKey(const Key('paperless_trend_menu_slower')))
            .dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const Key('paperless_trend_menu_faster')))
              .dy,
        ),
      );
      await tester.tap(
        find.byKey(const Key('paperless_trend_filter_improved')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('paperless_trend_menu_faster')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('paperless_trend_menu_slower')),
        findsNothing,
      );
      await tester.tap(find.byKey(const Key('paperless_trend_filter_all')));
      await tester.tap(find.byKey(const Key('paperless_trend_sort_improved')));
      await tester.pumpAndSettle();
      expect(
        tester
            .getTopLeft(find.byKey(const Key('paperless_trend_menu_faster')))
            .dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const Key('paperless_trend_menu_slower')))
              .dy,
        ),
      );
      expect(find.textContaining('기준 없음'), findsWidgets);
    },
  );

  testWidgets(
    'phone starts with the latest four periods and can go backwards',
    (tester) async {
      tester.view.physicalSize = const Size(390, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(_app());
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('paperless_trend_cell_slower_7')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('paperless_trend_cell_slower_0')),
        findsNothing,
      );
      expect(find.text('기록 없음'), findsWidgets);
      await tester.ensureVisible(
        find.byKey(const Key('paperless_trend_previous')),
      );
      await tester.tap(find.byKey(const Key('paperless_trend_previous')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('paperless_trend_cell_slower_0')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('paperless_trend_cell_slower_7')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('a baseline-only menu opens without inventing current samples', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        fixture: {
          ..._fixture(),
          'menus': [
            {
              ..._menu('previous', '이전 기간 메뉴', 300, 0),
              'current_average_seconds': null,
              'current_sample_count': 0,
              'points': <Map<String, dynamic>>[],
            },
          ],
        },
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('paperless_trend_menu_previous')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('paperless_trend_detail_previous')),
      findsOneWidget,
    );
    expect(find.textContaining('현재 기록 없음'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('new periods reset selection and window', (tester) async {
    await tester.pumpWidget(_app());
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('paperless_trend_menu_slower')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('paperless_trend_detail_slower')),
      findsOneWidget,
    );
    await tester.pumpWidget(
      _app(
        fixture: {
          ..._fixture(),
          'menus': [_menu('other', '다른 메뉴', 300, 600)],
        },
      ),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('paperless_trend_detail_slower')),
      findsNothing,
    );
    expect(find.byKey(const Key('paperless_trend_menu_other')), findsOneWidget);
  });

  for (final width in [390.0, 1440.0]) {
    testWidgets('full heatmap cells and inline graph visible at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, width < 600 ? 1400 : 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final output = Platform.environment['GLOBOS_TIMING_TREND_SCENES'];
      if (output != null) {
        await (FontLoader('Pretendard')
              ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf')))
            .load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      }
      await tester.pumpWidget(
        RepaintBoundary(key: const Key('trend_scene'), child: _app()),
      );
      await tester.pumpAndSettle();
      if (width < 600) {
        final bounds = tester.getRect(
          find.byType(PaperlessTimingTrendsSection),
        );
        for (final index in [4, 5, 6, 7]) {
          final rect = tester.getRect(
            find.byKey(Key('paperless_trend_cell_slower_$index')),
          );
          expect(rect.left, greaterThanOrEqualTo(bounds.left));
          expect(rect.right, lessThanOrEqualTo(bounds.right));
        }
      }
      await tester.tap(find.byKey(const Key('paperless_trend_menu_slower')));
      await tester.pumpAndSettle();
      final detail = tester.getRect(
        find.byKey(const Key('paperless_trend_detail_slower')),
      );
      final nextMenu = tester.getRect(
        find.byKey(const Key('paperless_trend_menu_stable')),
      );
      expect(detail.bottom, lessThan(nextMenu.top));
      expect(tester.takeException(), isNull);
      if (output != null) {
        final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const Key('trend_scene')),
        );
        await tester.runAsync(() async {
          final image = await boundary.toImage(pixelRatio: 1);
          final data = await image.toByteData(format: ui.ImageByteFormat.png);
          final file = File('$output/timing_trends_${width.toInt()}.png');
          file.parent.createSync(recursive: true);
          file.writeAsBytesSync(data!.buffer.asUint8List());
          image.dispose();
        });
      }
    });
  }

  testWidgets('out-of-order responses cannot replace the new period', (
    tester,
  ) async {
    final old = Completer<Map<String, dynamic>>();
    final current = Completer<Map<String, dynamic>>();
    var calls = 0;
    Future<Map<String, dynamic>> report() async => {'order_count': 1};
    Future<Map<String, dynamic>> trend({
      required String storeId,
      required DateTime startDate,
      required DateTime endDate,
    }) {
      calls++;
      return startDate.day == 1 ? old.future : current.future;
    }

    Widget dashboard(int day) => _app(
      child: PaperlessOperationsDashboard(
        storeId: 'test-store',
        startDate: DateTime(2026, 10, day),
        endDate: DateTime(2026, 10, day),
        loader: report,
        trendLoader: trend,
      ),
    );
    await tester.pumpWidget(dashboard(1));
    await tester.pump();
    await tester.pumpWidget(dashboard(2));
    current.complete({
      ..._fixture(),
      'menus': [_menu('current', '현재 메뉴', 300, 600)],
    });
    await tester.pumpAndSettle();
    old.complete({
      ..._fixture(),
      'menus': [_menu('old', '과거 메뉴', 300, 600)],
    });
    await tester.pumpAndSettle();
    expect(calls, 2);
    expect(
      find.byKey(const Key('paperless_trend_menu_current')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('paperless_trend_menu_old')), findsNothing);
  });

  testWidgets('failed trend request preserves the established report', (
    tester,
  ) async {
    await tester.pumpWidget(
      _app(
        child: PaperlessOperationsDashboard(
          storeId: 'test-store',
          startDate: DateTime(2026, 10, 1),
          endDate: DateTime(2026, 10, 1),
          loader: () async => {'order_count': 1},
          trendLoader:
              ({
                required storeId,
                required startDate,
                required endDate,
              }) async => throw StateError('offline'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('기간별 데이터를 불러오지 못했습니다. 새로고침해 주세요.'), findsOneWidget);
    expect(
      find.byKey(const Key('paperless_operations_time_summary')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
}
