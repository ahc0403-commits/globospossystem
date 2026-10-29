import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/core/ui/toast/toast.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

import 'support/layout_geometry.dart';
import 'support/pos_layout_fixtures.dart';

Widget localizedSurface(Widget child, String language, double scale) =>
    MaterialApp(
      theme: AppTheme.build(),
      locale: Locale(language),
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: child,
    );

void setViewport(WidgetTester tester, Size size) {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      AppFonts.family,
    )..addFont(rootBundle.load(AppFonts.assetPath))).load();
  });
  for (final language in ['ko', 'en', 'vi']) {
    final title = switch (language) {
      'ko' => 'SAMPLE · 긴 매장 이름 · 운영성과 및 메뉴별 판매현황',
      'en' =>
        'SAMPLE · Long restaurant name · Operational performance and sales',
      _ =>
        'SAMPLE · Cửa hàng tên dài · Phân tích hiệu quả hoạt động và bán hàng',
    };
    for (final size in [
      const Size(390, 844),
      const Size(844, 390),
      const Size(1440, 900),
    ]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('shared topbar and monetary cells $language $size $scale', (
          tester,
        ) async {
          setViewport(tester, size);
          var actions = 0;
          await tester.pumpWidget(
            localizedSurface(
              Scaffold(
                body: Column(
                  children: [
                    ToastTopbar(
                      title: title,
                      leading: const Icon(Icons.store),
                      actions: [
                        TextButton(
                          onPressed: () => actions++,
                          child: const Text('SAMPLE ACTION'),
                        ),
                      ],
                      trailing: const Text(
                        'SAMPLE · Cửa hàng / 매장 / Restaurant',
                      ),
                    ),
                    Expanded(
                      child: ToastResponsiveScrollBody(
                        children: [
                          ToastMetricItemStrip(
                            items: [
                              for (var i = 0; i < 4; i++)
                                ToastMetricItem(
                                  label: '$title $i',
                                  value: '${i + 1}.999.999.999.999 VND',
                                ),
                            ],
                          ),
                          ToastDenseDataTable(
                            columns: [
                              for (var i = 0; i < 5; i++)
                                ToastDenseColumn(label: '$title $i'),
                            ],
                            rows: [
                              for (var i = 0; i < 8; i++)
                                ToastDenseRow(
                                  cells: [
                                    'SAMPLE $i',
                                    '123.456.789.999 VND',
                                    'SAMPLE · 긴 이름 / tên dài',
                                    'SAMPLE',
                                    'LAST CELL $i',
                                  ],
                                ),
                            ],
                          ),
                          const Text('SAMPLE END', key: Key('surface_end')),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              language,
              scale,
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          final heading = tester.widget<Text>(find.text(title));
          expect(heading.maxLines, isNull);
          expect(heading.overflow, isNot(TextOverflow.ellipsis));
          for (var i = 0; i < 4; i++) {
            final value = tester.widget<Text>(
              find.text('${i + 1}.999.999.999.999 VND'),
            );
            expect(value.maxLines, isNull);
            expect(value.overflow, isNot(TextOverflow.ellipsis));
          }
          await tester.tap(find.text('SAMPLE ACTION'));
          expect(actions, 1);
          await tester.ensureVisible(find.byKey(const Key('surface_end')));
          await tester.pumpAndSettle();
          expect(
            visiblePaintRect(
              tester,
              find.byKey(const Key('surface_end')),
            ).height,
            greaterThan(0),
          );
          final localScroll = find.byKey(
            const Key('toast_dense_table_horizontal_scroll'),
          );
          if (localScroll.evaluate().isNotEmpty) {
            await tester.ensureVisible(localScroll);
            await tester.drag(localScroll, const Offset(-1200, 0));
            await tester.pumpAndSettle();
            await tester.ensureVisible(find.text('LAST CELL 0'));
            await tester.pumpAndSettle();
            expect(
              visiblePaintRect(tester, find.text('LAST CELL 0')).width,
              greaterThan(0),
            );
          }
          expect(tester.takeException(), isNull);
        });
      }
    }
    for (final size in const [
      Size(599, 844),
      Size(600, 844),
      Size(1023, 768),
      Size(1024, 768),
      Size(1439, 900),
      Size(1440, 390),
    ]) {
      testWidgets('full navigation shell $language $size large text', (
        tester,
      ) async {
        setViewport(tester, size);
        var selected = 0;
        await tester.pumpWidget(
          localizedSurface(
            ToastSidebar(
              title: title,
              groups: [
                ToastSidebarGroup(
                  title: 'SAMPLE',
                  items: [
                    for (var i = 0; i < 11; i++)
                      ToastSidebarItem(
                        icon: Icons.inventory_2_outlined,
                        label: '$title $i',
                        itemKey: Key('sample_nav_$i'),
                      ),
                  ],
                ),
              ],
              selectedIndex: 0,
              onItemSelected: (i) => selected = i,
              topBarTrailing: const Text('SAMPLE'),
              body: const ToastResponsiveScrollBody(
                children: [Text('SAMPLE WORKSPACE')],
              ),
            ),
            language,
            2,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('SAMPLE WORKSPACE'), findsOneWidget);
        expect(tester.takeException(), isNull);
        final selector = find.byKey(
          const Key('toast_compact_section_selector'),
        );
        if (selector.evaluate().isNotEmpty) {
          await tester.tap(selector);
          await tester.pumpAndSettle();
          final last = find.text('$title 10').last;
          await tester.ensureVisible(last);
          await tester.pumpAndSettle();
          await tester.tap(last);
        } else {
          final last = find.byKey(const Key('sample_nav_10'));
          if (last.evaluate().isEmpty) {
            await tester.scrollUntilVisible(
              last,
              150,
              scrollable: find.byType(Scrollable).first,
            );
          }
          await tester.ensureVisible(last);
          await tester.pumpAndSettle();
          await tester.tap(last);
        }
        await tester.pumpAndSettle();
        expect(selected, 10);
        expect(tester.takeException(), isNull);
      });
    }
    for (final scene in ['empty', 'loading', 'error']) {
      testWidgets('reports $scene remains readable $language large text', (
        tester,
      ) async {
        setViewport(tester, const Size(390, 844));
        await tester.pumpWidget(
          reportsLayoutFixture(
            language: language,
            scale: 2,
            report: LayoutSampleReport(scene: scene),
          ),
        );
        // The loading scene deliberately keeps its progress animation running.
        await tester.pump(const Duration(milliseconds: 500));
        expect(tester.takeException(), isNull);
      });
    }
    testWidgets('confirmation stays reachable with keyboard $language', (
      tester,
    ) async {
      setViewport(tester, const Size(390, 844));
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      addTearDown(tester.view.resetViewInsets);
      bool? result;
      await tester.pumpWidget(
        localizedSurface(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => unawaited(
                  ToastConfirmDialog.withContent(
                    context: context,
                    title: title,
                    content: const TextField(
                      decoration: InputDecoration(
                        labelText: 'SAMPLE · Lý do / 사유 / Reason',
                      ),
                    ),
                    confirmLabel: 'SAMPLE · Xác nhận / 확인 / Confirm',
                  ).then((value) => result = value),
                ),
                child: const Text('OPEN'),
              ),
            ),
          ),
          language,
          2,
        ),
      );
      await tester.tap(find.text('OPEN'));
      await tester.pumpAndSettle();
      final confirm = find.byKey(const Key('toast_confirm_dialog_confirm'));
      await tester.ensureVisible(confirm);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final confirmText = tester.widget<Text>(
        find.text('SAMPLE · Xác nhận / 확인 / Confirm'),
      );
      expect(confirmText.maxLines, isNull);
      expect(confirmText.overflow, isNot(TextOverflow.ellipsis));
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(result, isTrue);
      expect(tester.takeException(), isNull);
    });
  }
}
