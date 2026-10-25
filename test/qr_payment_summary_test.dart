import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/qr_order_service.dart';
import 'package:globos_pos_system/features/qr_order/qr_payment_summary.dart';

void main() {
  setUpAll(() async {
    final font = FontLoader('Pretendard')
      ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf'));
    await font.load();
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
  });
  test(
    'payment summary accepts numeric strings and never invents missing zero',
    () {
      final json = <String, Object?>{
        'currency': 'VND',
        'total_amount': '77760.00',
        'paid_total': 10000,
        'remaining_due': 67760,
        'calculated_at': '2026-10-24T10:00:00Z',
      };
      expect(QrPaymentSummary.fromJson(json)!.remainingDue, 67760);
      expect(
        QrPaymentSummary.fromJson({...json, 'remaining_due': null}),
        isNull,
      );
      expect(
        QrPaymentSummary.fromJson({...json, 'remaining_due': 'NaN'}),
        isNull,
      );
      expect(QrPaymentSummary.fromJson({...json, 'currency': 'USD'}), isNull);
      expect(QrPaymentSummary.fromJson(null), isNull);
      expect(
        QrPaymentSummary.fromJson({...json, 'remaining_due': 0})!.remainingDue,
        0,
      );
    },
  );

  for (final language in ['ko', 'vi', 'en']) {
    testWidgets(
      'cumulative balance and partial payment are readable in $language',
      (tester) async {
        tester.view.physicalSize = const Size(320, 850);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        var refreshes = 0;
        final boundary = GlobalKey();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(fontFamily: 'Pretendard'),
            home: Scaffold(
              body: SingleChildScrollView(
                child: RepaintBoundary(
                  key: boundary,
                  child: MediaQuery(
                    data: const MediaQueryData(
                      textScaler: TextScaler.linear(2),
                    ),
                    child: QrPaymentSummaryCard(
                      summary: QrPaymentSummary(
                        totalAmount: 77760,
                        paidTotal: 10000,
                        remainingDue: 67760,
                        calculatedAt: DateTime.utc(2026, 10, 24),
                      ),
                      languageCode: language,
                      isStale: false,
                      isLoading: false,
                      onRefresh: () => refreshes++,
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(find.text('67.760 ₫'), findsOneWidget);
        expect(find.textContaining('77.760 ₫'), findsOneWidget);
        expect(find.textContaining('10.000 ₫'), findsOneWidget);
        await tester.ensureVisible(
          find.byKey(const Key('qr_payment_summary_refresh')),
        );
        await tester.tap(find.byKey(const Key('qr_payment_summary_refresh')));
        await tester.pump();
        expect(refreshes, 1);
        expect(tester.takeException(), isNull);
        final output = Platform.environment['QR_BALANCE_SCREENSHOT_DIR'];
        if (output != null) {
          await tester.runAsync(() async {
            final image =
                await (boundary.currentContext!.findRenderObject()
                        as RenderRepaintBoundary)
                    .toImage();
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await File(
              '$output/payment-summary-$language.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      },
    );
  }

  testWidgets('unavailable balance is distinct from a confirmed zero', (
    tester,
  ) async {
    Future<void> show(QrPaymentSummary? summary, bool stale) =>
        tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(fontFamily: 'Pretendard'),
            home: Scaffold(
              body: QrPaymentSummaryCard(
                summary: summary,
                languageCode: 'ko',
                isStale: stale,
                isLoading: false,
                onRefresh: () {},
              ),
            ),
          ),
        );
    await show(null, true);
    expect(find.text('—'), findsOneWidget);
    expect(find.text('0 ₫'), findsNothing);
    await show(
      QrPaymentSummary(
        totalAmount: 0,
        paidTotal: 0,
        remainingDue: 0,
        calculatedAt: DateTime.utc(2026),
      ),
      false,
    );
    expect(find.text('0 ₫'), findsOneWidget);
  });
}
