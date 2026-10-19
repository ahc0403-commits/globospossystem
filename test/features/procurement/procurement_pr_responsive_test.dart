import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/procurement/procurement_workspace.dart';
import 'package:globos_pos_system/features/procurement/procurement_process_labels.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUpAll(() async {
    await (FontLoader(
      'Pretendard',
    )..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  for (final locale in ['ko', 'en', 'vi']) {
    testWidgets(
      'uncertain save remains readable and retryable in $locale at 390',
      (tester) async {
        tester.view.physicalSize = const Size(390, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final save = {'ko': '저장', 'en': 'Save', 'vi': 'Lưu'}[locale]!;
        final retry = {
          'ko': '같은 요청 재시도',
          'en': 'Retry saved request',
          'vi': 'Thử lại',
        }[locale]!;
        var pending = false;
        var retries = 0;
        await tester.pumpWidget(
          RepaintBoundary(
            key: const Key('pr-retry-preview'),
            child: MaterialApp(
              locale: Locale(locale),
              supportedLocales: const [
                Locale('ko'),
                Locale('en'),
                Locale('vi'),
              ],
              localizationsDelegates: GlobalMaterialLocalizations.delegates,
              theme: ThemeData(fontFamily: 'Pretendard'),
              home: Builder(
                builder: (context) => Scaffold(
                  body: TextButton(
                    child: const Text('Open'),
                    onPressed: () => showDialog<void>(
                      context: context,
                      builder: (_) => ProcurementRequestDialog(
                        products: const [
                          {
                            'id': 'item',
                            'name': 'Example beverage / Đồ uống mẫu',
                            'stock_unit': 'box',
                            'base_unit': 'box',
                          },
                        ],
                        supplierItems: const [],
                        initial: const {
                          'reason': '가상 자료 / Example / Dữ liệu giả',
                          'requested_delivery_date': '2026-10-09',
                          'lines': [
                            {
                              'product_id': 'item',
                              'requested_quantity': 1,
                              'requested_unit': 'box',
                            },
                          ],
                        },
                        saveRequest: (_) async {
                          pending = true;
                          return procurementProcessLabel('saveFailed', locale);
                        },
                        needsConfirmation: () => pending,
                        retrySavedRequest: () async {
                          retries++;
                          pending = false;
                          return null;
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('Open'));
        await tester.pumpAndSettle();
        await tester.tap(find.widgetWithText(FilledButton, save));
        await tester.pumpAndSettle();
        expect(find.widgetWithText(FilledButton, retry), findsOneWidget);
        await tester.ensureVisible(
          find.text(procurementProcessLabel('saveFailed', locale)),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        if (Platform.environment['PROCUREMENT_UI_CAPTURE'] == '1') {
          await expectLater(
            find.byKey(const Key('pr-retry-preview')),
            matchesGoldenFile('/tmp/pos-pr-ui-20261007/retry-$locale-390.png'),
          );
        }
        await tester.tap(find.widgetWithText(FilledButton, retry));
        await tester.pumpAndSettle();
        expect(retries, 1);
        expect(find.byType(ProcurementRequestDialog), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
    for (final width in [390.0, 1440.0]) {
      testWidgets('PR navigation and filters fit $locale at $width', (
        tester,
      ) async {
        SharedPreferences.setMockInitialValues({});
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var receiving = 0;
        var historical = 0;
        String copy(String key) => procurementProcessLabel(key, locale);
        final page = ProcurementWorkspacePage(
          requesterView: true,
          onOpenReceiving: () => receiving++,
          onOpenLegacy: () => historical++,
          onLogout: () {},
          load: () async => {},
          loadPage: (query) async => {
            'contract_version': 2,
            'enabled': true,
            'store_id': 'sample',
            'actor': {
              'system': 'pos',
              'subject_id': 'sample-requester',
              'can_create': true,
            },
            'request_counts': {'pending': 3, 'approved': 2, 'cancelled': 1},
            'requests': List.generate(
              3,
              (i) => {
                'id': 'pr-$i',
                'request_no': 'PR-EXAMPLE-${i + 1}',
                'status': i == 0 ? 'submitted' : 'draft',
                'created_at': '2026-10-06T17:30:00Z',
                'requested_delivery_date': '2026-10-09',
                'purchase_category': i == 0 ? 'beverage' : 'raw_material',
                'line_count': 11,
                'reason': '가상 검토 자료 / Dữ liệu giả để kiểm tra',
                'allowed_actions': [],
              },
            ),
            'orders': [],
            'products': [],
            'supplier_items': [],
          },
          execute: (a, b, c, d, e) async => {},
        );
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            supportedLocales: const [Locale('ko'), Locale('en'), Locale('vi')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            theme: ThemeData(fontFamily: 'Pretendard'),
            home: RepaintBoundary(key: const Key('pr-preview'), child: page),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(copy('management')), findsOneWidget);
        expect(find.text(copy('operatingMetrics')), findsNothing);
        expect(find.textContaining('2026-10-06T17:'), findsNothing);
        expect(tester.takeException(), isNull);
        if (Platform.environment['PROCUREMENT_UI_CAPTURE'] == '1') {
          await expectLater(
            find.byKey(const Key('pr-preview')),
            matchesGoldenFile(
              '/tmp/pos-pr-ui-20261007/pr-$locale-${width.toInt()}.png',
            ),
          );
        }
        if (width < 600) {
          await tester.tap(find.byType(PopupMenuButton<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text(copy('receiving')));
          await tester.pumpAndSettle();
        } else {
          await tester.tap(find.widgetWithText(TextButton, copy('receiving')));
          await tester.pumpAndSettle();
          await tester.tap(
            find.widgetWithText(TextButton, copy('legacyOrders')),
          );
          await tester.pumpAndSettle();
          expect(historical, 1);
        }
        expect(receiving, 1);
        expect(tester.takeException(), isNull);
      });
    }
  }
}
