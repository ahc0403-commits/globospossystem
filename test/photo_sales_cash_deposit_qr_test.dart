import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/cash_deposit_transfer.dart';
import 'package:globos_pos_system/features/report/cash_deposit_qr_dialog.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/daily_sales_report_service.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'daily_sales_report_service_test.dart' as fixtures;

Map<String, dynamic> entity({bool second = false}) => fixtures.row()
  ..addAll({
    'tax_entity_id': second ? 'entity-2' : 'entity-1',
    'seller_tax_code': second ? '002' : '001',
    'seller_legal_name': second ? 'Entity Two' : 'Entity One',
    'photo_gross': second ? 216001 : 108001,
    'bank': {
      'bin': '970426',
      'account_number': second ? '12345678902' : '12345678901',
      'account_holder': second ? 'FIXTURE TWO' : 'FIXTURE ONE',
      'label': 'Fixture Bank',
    },
  });

Future<void> mount(
  WidgetTester tester, {
  required DailySalesReportService service,
  double width = 1024,
  double scale = 1,
  String locale = 'ko',
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.build(),
      locale: Locale(locale),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(scale)),
        child: RepaintBoundary(key: const Key('photo_qr_scene'), child: child!),
      ),
      home: Scaffold(
        body: RestaurantSalesExportScreen(
          embedded: true,
          initialBusinessDate: '2026-10-16',
          todayOverride: DateTime(2026, 10, 17),
          reportService: service,
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> openQr(WidgetTester tester) async {
  final open = find.byKey(const Key('sales_deposit_photo_secondary_action'));
  await tester.ensureVisible(open);
  await tester.pumpAndSettle();
  await tester.tap(open);
  await tester.pumpAndSettle();
}

Future<void> generate(WidgetTester tester) async {
  final button = find.byKey(const Key('cash_deposit_generate_qr'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  await tester.tap(button);
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() async {
    await (FontLoader(
      AppFonts.family,
    )..addFont(rootBundle.load(AppFonts.assetPath))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets(
    'photo sales total QR uses the selected entity amount account and query date',
    (tester) async {
      var calls = 0;
      final service = DailySalesReportService(
        rpc: (name, p) async {
          calls++;
          expect(name, 'get_pos_daily_sales_summary');
          return {
            'business_date': p['p_business_date'],
            'entities': [entity(), entity(second: true)],
          };
        },
      );
      await mount(tester, service: service);
      final selector = find.byKey(
        const Key('restaurant_sales_export_tax_entity_selector'),
      );
      await tester.ensureVisible(selector);
      await tester.tap(selector);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Entity Two · 002').last);
      await tester.pumpAndSettle();
      final card = find.byKey(const Key('sales_deposit_photo'));
      // Both the card heading and the explicit QR action open the same dialog.
      final heading = find
          .descendant(of: card, matching: find.byType(Text))
          .first;
      await tester.ensureVisible(heading);
      await tester.tap(heading);
      await tester.pumpAndSettle();
      final dialog = tester.widget<CashDepositQrDialog>(
        find.byType(CashDepositQrDialog),
      );
      expect(dialog.scopeLabel, 'Photo Objet · Entity Two');
      expect(dialog.reportDate, DateTime(2026, 10, 16));
      expect(dialog.amount, 216001);
      expect(dialog.purpose, 'PO Cash Doanh thu 16/10');
      final bank = await dialog.loadBank();
      expect(bank.accountNumber, '12345678902');
      expect(bank.accountHolder, 'FIXTURE TWO');
      expect(
        find.descendant(
          of: find.byType(CashDepositQrDialog),
          matching: find.byType(TextFormField),
        ),
        findsNothing,
      );
      expect(
        tester
            .widget<SelectableText>(
              find.byKey(const Key('cash_deposit_amount')),
            )
            .data,
        '216.001 VND',
      );
      await generate(tester);
      final paint = tester.widget<CustomPaint>(
        find.descendant(
          of: find.byType(QrImageView),
          matching: find.byType(CustomPaint),
        ),
      );
      await tester.runAsync(() async {
        final actual = await (paint.painter! as QrPainter).toImageData(300);
        final expected = await QrPainter(
          data: cashDepositQrPayload(
            bank: bank,
            amount: 216001,
            purpose: 'PO Cash Doanh thu 16/10',
          ),
          version: QrVersions.auto,
          gapless: true,
        ).toImageData(300);
        expect(actual!.buffer.asUint8List(), expected!.buffer.asUint8List());
      });
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  for (final width in [390.0, 768.0, 1440.0]) {
    for (final locale in ['ko', 'vi', 'en']) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('photo summary QR $width/$locale/$scale', (tester) async {
          var calls = 0;
          await mount(
            tester,
            width: width,
            locale: locale,
            scale: scale,
            service: DailySalesReportService(
              rpc: (name, p) async {
                calls++;
                return {
                  'business_date': p['p_business_date'],
                  'entities': [entity()],
                };
              },
            ),
          );
          await openQr(tester);
          expect(find.textContaining('16/10/2026'), findsOneWidget);
          expect(find.text('PO Cash Doanh thu 16/10'), findsOneWidget);
          expect(
            tester
                .widget<SelectableText>(
                  find.byKey(const Key('cash_deposit_amount')),
                )
                .data,
            '108.001 VND',
          );
          await generate(tester);
          expect(find.byType(QrImageView), findsOneWidget);
          expect(calls, 1);
          expect(tester.takeException(), isNull);
          final output = Platform.environment['GLOBOS_CASH_DEPOSIT_SCENES'];
          if (output != null && locale == 'ko' && scale == 1) {
            await tester.ensureVisible(
              find.byKey(const Key('cash_deposit_qr')),
            );
            await tester.pumpAndSettle();
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('photo_qr_scene')),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 1);
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              File(
                '$output/photo_deposit_${width.toInt()}.png',
              ).writeAsBytesSync(data!.buffer.asUint8List());
              image.dispose();
            });
          }
        });
      }
    }
  }

  testWidgets(
    'changing the Photo query date clears stale amounts until lookup',
    (tester) async {
      final days = <String>[];
      await mount(
        tester,
        service: DailySalesReportService(
          rpc: (name, p) async {
            final day = p['p_business_date'] as String;
            days.add(day);
            return {
              'business_date': day,
              'entities': [
                entity()
                  ..['photo_gross'] = day.endsWith('15') ? 987001 : 108001,
              ],
            };
          },
        ),
      );
      final picker = find.byKey(
        const Key('restaurant_sales_export_date_picker'),
      );
      await tester.ensureVisible(picker);
      await tester.pumpAndSettle();
      await tester.tap(picker);
      await tester.pumpAndSettle();
      await tester.tap(find.text('15').last);
      await tester.tap(find.text('확인'));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sales_deposit_photo')), findsNothing);
      expect(days, ['2026-10-16']);
      await tester.tap(find.byKey(const Key('restaurant_sales_export_search')));
      await tester.pumpAndSettle();
      await openQr(tester);
      final dialog = tester.widget<CashDepositQrDialog>(
        find.byType(CashDepositQrDialog),
      );
      expect(dialog.reportDate, DateTime(2026, 10, 15));
      expect(dialog.amount, 987001);
      expect(dialog.purpose, 'PO Cash Doanh thu 15/10');
      expect(days, ['2026-10-16', '2026-10-15']);
    },
  );

  for (final invalid in [
    'missing bank',
    'incomplete photo import',
    'zero photo amount',
  ]) {
    testWidgets('$invalid blocks photo QR without an extra request', (
      tester,
    ) async {
      var calls = 0;
      final row = entity();
      if (invalid == 'missing bank') row['bank'] = null;
      if (invalid == 'incomplete photo import') row['photo_complete'] = false;
      if (invalid == 'zero photo amount') row['photo_gross'] = 0;
      await mount(
        tester,
        service: DailySalesReportService(
          rpc: (name, p) async {
            calls++;
            return {
              'business_date': p['p_business_date'],
              'entities': [row],
            };
          },
        ),
      );
      await openQr(tester);
      expect(find.byType(CashDepositQrDialog), findsNothing);
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    });
  }
}
