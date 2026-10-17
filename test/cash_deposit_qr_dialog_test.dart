import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/cash_deposit_transfer.dart';
import 'package:globos_pos_system/core/payments/collection_bank.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/report/cash_deposit_qr_dialog.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:qr_flutter/qr_flutter.dart';

const bank = CollectionBank(
  bin: '970426',
  accountNumber: '12345678901',
  accountHolder: 'FIXTURE COMPANY',
  label: 'Fixture Bank',
);

Widget app({
  required Future<CollectionBank> Function() loadBank,
  String locale = 'ko',
  double scale = 1,
}) => MaterialApp(
  theme: AppTheme.build(),
  locale: Locale(locale),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(scale)),
    child: RepaintBoundary(key: const Key('scene'), child: child!),
  ),
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        key: const Key('open'),
        onPressed: () => showDialog<void>(
          context: context,
          builder: (_) => CashDepositQrDialog(
            scopeLabel: 'Bunsikclub · Binh Thanh',
            purpose: 'BC BT Cash Doanhthu 16/10',
            loadBank: loadBank,
            // Historical query date is passed as a calendar date, not today.
            reportDate: DateTime(2026, 10, 16),
            amount: 1622160,
          ),
        ),
        child: const Text('Open'),
      ),
    ),
  ),
);

Future<void> generate(WidgetTester tester) async {
  final button = find.byKey(const Key('cash_deposit_generate_qr'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
}

Future<void> expectQrAmount(WidgetTester tester, int amount) async {
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
        amount: amount,
        purpose: 'BC BT Cash Doanhthu 16/10',
      ),
      version: QrVersions.auto,
      gapless: true,
    ).toImageData(300);
    expect(actual!.buffer.asUint8List(), expected!.buffer.asUint8List());
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      AppFonts.family,
    )..addFont(rootBundle.load(AppFonts.assetPath))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });

  for (final width in [390.0, 768.0, 1440.0]) {
    for (final locale in ['ko', 'vi', 'en']) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('cash deposit QR $width/$locale/$scale', (tester) async {
          await tester.binding.setSurfaceSize(Size(width, 1100));
          addTearDown(() => tester.binding.setSurfaceSize(null));
          var loads = 0;
          await tester.pumpWidget(
            app(
              locale: locale,
              scale: scale,
              loadBank: () async {
                loads++;
                return bank;
              },
            ),
          );
          await tester.tap(find.byKey(const Key('open')));
          await tester.pumpAndSettle();
          expect(find.textContaining('16/10/2026'), findsOneWidget);
          expect(find.text('BC BT Cash Doanhthu 16/10'), findsOneWidget);
          expect(find.byType(TextFormField), findsNothing);
          expect(
            tester
                .widgetList<EditableText>(find.byType(EditableText))
                .every((field) => field.readOnly),
            isTrue,
          );
          await generate(tester);
          await expectQrAmount(tester, 1622160);
          expect(find.text('1.622.160 VND'), findsOneWidget);
          expect(loads, 1);
          expect(tester.takeException(), isNull);

          final output = Platform.environment['GLOBOS_CASH_DEPOSIT_SCENES'];
          if (output != null && locale == 'ko' && scale == 1) {
            await tester.ensureVisible(
              find.byKey(const Key('cash_deposit_qr')),
            );
            await tester.pumpAndSettle();
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('scene')),
            );
            await tester.runAsync(() async {
              final image = await boundary.toImage(pixelRatio: 1);
              final bytes = await image.toByteData(
                format: ui.ImageByteFormat.png,
              );
              final file = File('$output/cash_deposit_${width.toInt()}.png');
              file.parent.createSync(recursive: true);
              file.writeAsBytesSync(bytes!.buffer.asUint8List());
              image.dispose();
            });
          }
        });
      }
    }
  }

  testWidgets(
    'copy and rebuild preserve the fixed report amount and exact QR memo',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(768, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String;
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      var loads = 0;
      await tester.pumpWidget(
        app(
          loadBank: () async {
            loads++;
            return bank;
          },
        ),
      );
      await tester.tap(find.byKey(const Key('open')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widgetList<EditableText>(find.byType(EditableText))
            .every((field) => field.readOnly),
        isTrue,
      );
      await generate(tester);
      await expectQrAmount(tester, 1622160);
      await tester.ensureVisible(
        find.byKey(const Key('cash_deposit_copy_purpose')),
      );
      await tester.tap(find.byKey(const Key('cash_deposit_copy_purpose')));
      await tester.pumpAndSettle();
      expect(copied, 'BC BT Cash Doanhthu 16/10');
      expect(find.text('적요 복사됨'), findsOneWidget);
      await generate(tester);
      await expectQrAmount(tester, 1622160);
      expect(find.text('1.622.160 VND'), findsOneWidget);
      expect(loads, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('bank failures block generation and retry only on request', (
    tester,
  ) async {
    final response = Completer<CollectionBank>();
    var loads = 0;
    await tester.pumpWidget(
      app(
        loadBank: () {
          loads++;
          return loads == 1 ? response.future : Future.value(bank);
        },
      ),
    );
    await tester.tap(find.byKey(const Key('open')));
    await tester.pump();
    expect(find.byKey(const Key('cash_deposit_generate_qr')), findsNothing);
    response.completeError(const FormatException('fixture bank unavailable'));
    await tester.pumpAndSettle();
    expect(loads, 1);
    expect(find.byType(QrImageView), findsNothing);
    final retry = find.byKey(const Key('cash_deposit_retry_bank'));
    await tester.ensureVisible(retry);
    await tester.tap(retry);
    await tester.pumpAndSettle();
    await generate(tester);
    expect(find.byType(QrImageView), findsOneWidget);
    expect(loads, 2);
    expect(tester.takeException(), isNull);
  });
}
