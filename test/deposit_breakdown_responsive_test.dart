import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/daily_deposit_panel.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/daily_sales_summary.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:globos_pos_system/widgets/bank_transfer_ledger_dialog.dart';
import 'daily_sales_report_service_test.dart' as fixtures;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    final loader = FontLoader(AppFonts.family)
      ..addFont(rootBundle.load(AppFonts.assetPath));
    await loader.load();
  });
  for (final width in [360.0, 375.0, 390.0, 412.0, 768.0, 1024.0, 1440.0]) {
    for (final scale in [1.0, 1.3, 2.0]) {
      for (final locale in ['ko', 'vi', 'en']) {
        testWidgets('separate deposits $width/$scale/$locale', (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 1100));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          final s = DailySalesSummary.fromJson(
            '2026-10-15',
            fixtures.row()..addAll({
              'photo_gross': 10000000,
              'restaurant_bank_transfer': 3000000,
              'bunsik_closed_deposit': 1623000,
              'bunsik_cash': 1622160,
              'bunsik_expected_deposit': 1622160,
              'bunsik_variance_store_count': 1,
              'bunsik_variance': 840,
              'bank': {
                'bin': '970426',
                'label': 'MSB',
                'account_number': '80002014298',
                'account_holder': 'AKJ INTERNATIONAL CO., LTD',
              },
            }),
          );
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
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  child: Padding(
                    padding: const EdgeInsets.all(12),
                    child: RepaintBoundary(
                      key: const Key('deposit_scene'),
                      child: ColoredBox(
                        color: Colors.white,
                        child: DailyDepositPanel(summary: s),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          for (final key in [
            'sales_deposit_bank',
            'sales_deposit_photo',
            'sales_deposit_cash',
          ]) {
            expect(find.byKey(Key(key)), findsOneWidget);
          }
          expect(find.text('3.000.000 VND'), findsOneWidget);
          expect(find.text('10.000.000 VND'), findsOneWidget);
          expect(find.text('1.622.160 VND'), findsOneWidget);
          expect(find.textContaining('1.623.000 VND'), findsOneWidget);
          expect(find.textContaining('840 VND'), findsOneWidget);
          expect(find.textContaining('11.622.160 VND'), findsOneWidget);
          expect(find.textContaining('2026-10-16'), findsNWidgets(2));
          final bankY = tester
              .getTopLeft(find.byKey(const Key('sales_deposit_bank')))
              .dy;
          final photoY = tester
              .getTopLeft(find.byKey(const Key('sales_deposit_photo')))
              .dy;
          if (width < 600 || scale >= 1.3) expect(photoY, greaterThan(bankY));
          if (width >= 1024 && scale == 1) expect(photoY, bankY);
          expect(tester.takeException(), isNull);
          final output = Platform.environment['GLOBOS_DEPOSIT_SCENES'];
          if (output != null &&
              locale == 'ko' &&
              scale == 1 &&
              [390.0, 768.0, 1440.0].contains(width)) {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('deposit_scene')),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 1);
              final data = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File('$output/deposit_${width.toInt()}.png');
              file.parent.createSync(recursive: true);
              file.writeAsBytesSync(data!.buffer.asUint8List());
              image.dispose();
            });
          }
        });
      }
    }
  }
  testWidgets('transfer details paginate without per-row calls', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ko'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: BankTransferLedgerDialog(
            loadPage: (time, id) async {
              calls++;
              final start = id == null ? 0 : int.parse(id) + 1;
              return {
                'has_more': start + 100 < 205,
                'rows': [
                  for (var i = start; i < 205 && i < start + 100; i++)
                    {
                      'payment_id': '$i',
                      'store_name': 'Bunsik',
                      'amount': 1000,
                      'created_at': '2026-10-12T00:00:00Z',
                      'receipt_number': 'R-$i',
                    },
                ],
              };
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);
    await tester.tap(find.text('다음 페이지'));
    await tester.pumpAndSettle();
    expect(calls, 2);
    await tester.tap(find.text('다음 페이지'));
    await tester.pumpAndSettle();
    expect(calls, 3);
    expect(find.text('다음 페이지'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
