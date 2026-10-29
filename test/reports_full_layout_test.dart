import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:globos_pos_system/core/ui/toast/toast.dart';
import 'support/pos_layout_fixtures.dart';
import 'support/layout_geometry.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      AppFonts.family,
    )..addFont(rootBundle.load(AppFonts.assetPath))).load();
  });
  for (final language in ['ko', 'en', 'vi']) {
    for (final size in [
      const Size(390, 844),
      const Size(768, 1024),
      const Size(1024, 768),
      const Size(1280, 800),
      const Size(1440, 900),
      const Size(1920, 1080),
      const Size(844, 390),
      const Size(1280, 390),
    ]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets(
          'whole reports $language ${size.width} ${size.height} $scale',
          (tester) async {
            tester.view.physicalSize = size;
            tester.view.devicePixelRatio = 1;
            addTearDown(tester.view.resetPhysicalSize);
            addTearDown(tester.view.resetDevicePixelRatio);
            final report = LayoutSampleReport();
            await tester.pumpWidget(
              reportsLayoutFixture(
                language: language,
                scale: scale,
                report: report,
              ),
            );
            await tester.pumpAndSettle();
            expect(
              MediaQuery.sizeOf(
                tester.element(find.byKey(const Key('reports_root'))),
              ),
              size,
            );
            expect(tester.takeException(), isNull);
            final launchers = [
              'paperless_operations_launcher',
              'menu_sales_analytics_launcher',
              'sales_revenue_analytics_launcher',
            ].map((key) => tester.getRect(find.byKey(Key(key)))).toList();
            for (final first in launchers) {
              for (final other in launchers) {
                if ((first.top - other.top).abs() < .5) {
                  expect(first.height, closeTo(other.height, .5));
                }
              }
            }
            final issue = find.byKey(const Key('reports_actionable_issues'));
            final invoice = find.byKey(const Key('reports_einvoice_issue'));
            await tester.ensureVisible(invoice);
            await tester.pumpAndSettle();
            final panel = tester.getRect(issue);
            expect(
              visiblePaintRect(tester, invoice).height,
              closeTo(tester.getSize(invoice).height, .5),
              reason:
                  'A tiny nested viewport must not hide the actionable row.',
            );
            expect(
              panel.contains(tester.getCenter(invoice)),
              isTrue,
              reason:
                  'The actionable issue must fit inside its actual panel, not its clipped overflow.',
            );
            await tester.tap(invoice);
            await tester.pumpAndSettle();
            expect(find.byType(BottomSheet), findsOneWidget);
            expect(find.textContaining('SAMPLE · Kiểm tra'), findsOneWidget);
            expect(report.loads, 1);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
  testWidgets('four supporting KPI tiles stay balanced and fully readable', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);
    for (final width in [
      390.0,
      599.0,
      600.0,
      768.0,
      1023.0,
      1024.0,
      1280.0,
      1440.0,
    ]) {
      tester.view.physicalSize = Size(width, 900);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: ToastMetricStrip(
                dense: true,
                metrics: [
                  for (var i = 0; i < 4; i++)
                    ToastMetric(
                      label: 'SAMPLE · Chỉ số với nội dung dài $i',
                      value: '${i + 1}.999.999.999 VND',
                    ),
                ],
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final cells = find.byWidgetPredicate(
        (w) => w is Container && w.constraints?.minHeight == 26,
      );
      expect(cells, findsNWidgets(4));
      final rows = <double, int>{};
      for (final element in cells.evaluate()) {
        final y = tester
            .getTopLeft(find.byElementPredicate((e) => e == element))
            .dy;
        rows[y] = (rows[y] ?? 0) + 1;
      }
      expect(rows.values.every((n) => n == 1 || n == 2 || n == 4), isTrue);
      for (var i = 0; i < 4; i++) {
        final text = tester.widget<Text>(find.text('${i + 1}.999.999.999 VND'));
        expect(text.overflow, isNot(TextOverflow.ellipsis));
        expect(text.maxLines, isNull);
      }
      expect(tester.takeException(), isNull);
    }
  });
}
