import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/admin/widgets/paperless_bottleneck_analysis.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

Map<String, dynamic> _metric(
  String stage,
  int current,
  int baseline, {
  int count = 24,
}) => {
  'stage': stage,
  'current_count': count,
  'baseline_count': count,
  'current_mean': current,
  'baseline_mean': baseline,
  'current_p90': count >= 20 ? current + 120 : null,
  'baseline_p90': count >= 20 ? baseline + 120 : null,
};
Map<String, dynamic> _fixture({String name = '양념 치킨', bool details = false}) =>
    {
      'baseline_from': '2026-09-24',
      'baseline_to': '2026-09-30',
      'bucket_unit': 'day',
      'stages': [
        _metric('kitchen', 600, 480),
        _metric('handoff', 120, 120),
        _metric('floor', 60, 120),
      ],
      'hours': [
        for (final stage in ['kitchen', 'handoff', 'floor'])
          for (var hour = 0; hour < 24; hour++)
            {..._metric(stage, 600, 480, count: 10), 'hour': hour},
      ],
      'menus': [
        {
          ..._metric('kitchen', 600, 480),
          'menu_key': 'chicken',
          'name_ko': name,
          'name_en': 'Chicken',
          'name_vi': 'Gà',
          'extra_seconds': 2880,
        },
      ],
      'menu_count': 1,
      'completed_count': 24,
      'points': [
        for (var i = 1; i <= 7; i++)
          {'date': '2026-10-0$i', 'count': 24, 'mean': 600, 'p90': 720},
      ],
      'baseline': {'count': 24, 'mean': 480, 'p90': 600},
      'sample_count': details ? 1 : 0,
      'samples': details
          ? [
              {
                'sample_key': 'line1',
                'order_id': '00000000-0000-4000-8000-000000000001',
                'workflow': 'kitchen_direct_to_floor',
                'received_at': '2026-10-01T12:00:00Z',
                'kitchen_done_at': '2026-10-01T12:10:00Z',
                'handoff_at': null,
                'served_at': '2026-10-01T12:11:00Z',
                'seconds': 600,
              },
            ]
          : [],
    };

Widget _app({
  PaperlessBottleneckLoader? loader,
  String store = 'store1',
  String locale = 'ko',
  double scale = 1,
  Widget? child,
}) => MaterialApp(
  locale: Locale(locale),
  theme: AppTheme.build(),
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: child!,
  ),
  home: Scaffold(
    body: SingleChildScrollView(
      child:
          child ??
          PaperlessBottleneckSection(
            storeId: store,
            startDate: DateTime(2026, 10, 1),
            endDate: DateTime(2026, 10, 7),
            loader: loader,
          ),
    ),
  ),
);

Future<Map<String, dynamic>> _loader({
  required String storeId,
  required DateTime startDate,
  required DateTime endDate,
  required String stage,
  int? hour,
  String? menuKey,
}) async => _fixture(details: menuKey != null);

void main() {
  test(
    'mean comparison needs 5 per period, P90 needs 20; missing is not zero',
    () {
      final small = PaperlessBottleneckMetric(
        _metric('floor', 600, 480, count: 4),
      );
      expect(small.value(false), 600);
      expect(small.delta(false), isNull);
      final ten = PaperlessBottleneckMetric(
        _metric('floor', 600, 480, count: 10),
      );
      expect(ten.delta(false), 120);
      expect(ten.delta(true), isNull);
      expect(
        PaperlessBottleneckAnalysis({}).metric('handoff').value(false),
        isNull,
      );
    },
  );

  testWidgets(
    'stage and hour filters drive menu selection and actual event timelines',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <String>[];
      await tester.pumpWidget(
        _app(
          loader:
              ({
                required storeId,
                required startDate,
                required endDate,
                required stage,
                hour,
                menuKey,
              }) async {
                calls.add('$stage/$hour/$menuKey');
                return _fixture(details: menuKey != null);
              },
        ),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('2026-09-24 – 2026-09-30'), findsOneWidget);
      await tester.tap(find.byKey(const Key('bottleneck_stage_floor')));
      await tester.pumpAndSettle();
      final cell = find.byKey(const Key('bottleneck_cell_floor_19'));
      await tester.ensureVisible(cell);
      await tester.tap(cell);
      await tester.pumpAndSettle();
      final menu = find.byKey(const Key('bottleneck_menu_chicken'));
      await tester.ensureVisible(menu);
      await tester.tap(menu);
      await tester.pumpAndSettle();
      final sample = find.byKey(const Key('bottleneck_sample_line1'));
      await tester.ensureVisible(sample);
      await tester.tap(sample);
      await tester.pumpAndSettle();
      expect(calls, [
        'kitchen/null/null',
        'floor/null/null',
        'floor/19/null',
        'floor/19/chicken',
      ]);
      expect(
        find.textContaining('10/01 19:10:00 (베트남, UTC+7)'),
        findsOneWidget,
      );
      expect(find.text('미기록 / 해당 동선 없음'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late response cannot replace a newer store selection', (
    tester,
  ) async {
    final delayed = Completer<Map<String, dynamic>>();
    Future<Map<String, dynamic>> loader({
      required String storeId,
      required DateTime startDate,
      required DateTime endDate,
      required String stage,
      int? hour,
      String? menuKey,
    }) => storeId == 'store1'
        ? delayed.future
        : Future.value(_fixture(name: '새 매장 메뉴'));
    await tester.pumpWidget(_app(loader: loader));
    await tester.pump();
    await tester.pumpWidget(_app(loader: loader, store: 'store2'));
    await tester.pumpAndSettle();
    delayed.complete(_fixture(name: '이전 매장 메뉴'));
    await tester.pumpAndSettle();
    expect(find.textContaining('이전 매장 메뉴'), findsNothing);
    expect(find.textContaining('새 매장 메뉴'), findsOneWidget);
  });

  testWidgets('failed slice is explicit and can retry without stale menus', (
    tester,
  ) async {
    var fail = true;
    await tester.pumpWidget(
      _app(
        loader:
            ({
              required storeId,
              required startDate,
              required endDate,
              required stage,
              hour,
              menuKey,
            }) async {
              if (fail) throw StateError('fixture');
              return _fixture();
            },
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('병목 분석을 불러오지 못했습니다.'), findsOneWidget);
    fail = false;
    await tester.tap(find.text('재시도'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bottleneck_menu_chicken')), findsOneWidget);
  });

  for (final width in [390.0, 800.0, 1440.0]) {
    for (final locale in ['ko', 'en', 'vi']) {
      testWidgets(
        '$locale at width $width and 200% text keeps charts and controls usable',
        (tester) async {
          tester.view.physicalSize = Size(width, 1000);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            _app(loader: _loader, locale: locale, scale: 2),
          );
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('bottleneck_cell_kitchen_12')),
            findsOneWidget,
          );
          expect(
            find.byKey(const Key('bottleneck_cell_kitchen_16')),
            findsNothing,
          );
          final next = find.byKey(const Key('bottleneck_hours_next'));
          await tester.ensureVisible(next);
          await tester.tap(next);
          await tester.pumpAndSettle();
          expect(
            find.byKey(const Key('bottleneck_cell_kitchen_19')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  for (final width in [390.0, 1440.0]) {
    testWidgets('bottleneck coordinated charts and preview at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 1300);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final output = Platform.environment['GLOBOS_BOTTLENECK_SCENES'];
      if (output != null) {
        await (FontLoader('Pretendard')
              ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf')))
            .load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      }
      await tester.pumpWidget(
        RepaintBoundary(
          key: const Key('bottleneck_scene'),
          child: _app(loader: _loader),
        ),
      );
      await tester.pumpAndSettle();
      if (width < 600) {
        final next = find.byKey(const Key('bottleneck_hours_next'));
        await tester.ensureVisible(next);
        await tester.tap(next);
        await tester.pumpAndSettle();
      }
      final cell = find.byKey(const Key('bottleneck_cell_kitchen_19'));
      await tester.ensureVisible(cell);
      await tester.tap(cell);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('bottleneck_menu_chicken')), findsOneWidget);
      expect(tester.takeException(), isNull);
      if (output != null) {
        for (final scene in ['detail', 'overview']) {
          if (scene == 'overview') {
            await tester.drag(
              find.byType(SingleChildScrollView),
              const Offset(0, 5000),
            );
            await tester.pumpAndSettle();
          }
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('bottleneck_scene')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 1);
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            final file = File('$output/bottleneck_${width.toInt()}_$scene.png');
            file.parent.createSync(recursive: true);
            file.writeAsBytesSync(bytes!.buffer.asUint8List());
            image.dispose();
          });
        }
      }
    });
  }

  testWidgets(
    'timeline rejects reversed timestamps instead of drawing misleading bars',
    (tester) async {
      await tester.pumpWidget(
        _app(
          child: const PaperlessRecordedTimeline(
            languageCode: 'ko',
            sample: {
              'received_at': '2026-10-01T12:00:00Z',
              'kitchen_done_at': '2026-10-01T12:15:00Z',
              'handoff_at': '2026-10-01T12:10:00Z',
              'served_at': '2026-10-01T12:20:00Z',
            },
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('이벤트 시각 순서를 확인해야 합니다.'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
