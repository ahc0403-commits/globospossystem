import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/payment/payment_recovery_panel.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final imageDir = Platform.environment['POS_PAYMENT_RECOVERY_SCREENSHOTS'];
  setUpAll(() async {
    if (imageDir != null) {
      final loader = FontLoader('RecoveryTest');
      for (final name in [
        '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
        '/usr/share/fonts/truetype/noto/NotoSans-Regular.ttf',
      ]) {
        loader.addFont(
          File(name).readAsBytes().then((b) => ByteData.sublistView(b)),
        );
      }
      await loader.load();
    }
  });
  for (final language in ['ko', 'en', 'vi']) {
    testWidgets(
      '$language recovery is actionable at narrow width and disables duplicate actions',
      (tester) async {
        tester.view.physicalSize = const Size(360, 800);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final records = [
          {
            'amount': 10000,
            'method': 'CASH',
            'operation': 'original',
            'tableNumber': '3',
          },
        ];
        var checks = 0, cancels = 0;
        Future<void> pump({bool busy = false, int count = 1}) async {
          await tester.pumpWidget(
            MaterialApp(
              locale: Locale(language),
              theme: imageDir == null
                  ? null
                  : ThemeData(fontFamily: 'RecoveryTest'),
              localizationsDelegates: AppLocalizations.localizationsDelegates,
              supportedLocales: AppLocalizations.supportedLocales,
              home: Scaffold(
                body: RepaintBoundary(
                  key: const Key('capture'),
                  child: PaymentRecoveryPanel(
                    records: List.generate(count, (_) => records.single),
                    busy: busy,
                    onCheck: (r) {
                      expect(identical(r, records.single), isTrue);
                      checks++;
                    },
                    onCancel: (r) {
                      expect(identical(r, records.single), isTrue);
                      cancels++;
                    },
                    onReload: () {},
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
        }

        await pump();
        await tester.tap(find.byType(OutlinedButton).first);
        await tester.tap(find.byType(TextButton).first);
        expect(checks, 1);
        expect(cancels, 1);
        expect(tester.takeException(), isNull);

        if (imageDir != null) {
          await tester.runAsync(() async {
            final boundary = tester.renderObject<RenderRepaintBoundary>(
              find.byKey(const Key('capture')),
            );
            final image = await boundary.toImage();
            final bytes = await image.toByteData(
              format: ui.ImageByteFormat.png,
            );
            image.dispose();
            await Directory(imageDir).create(recursive: true);
            await File(
              '$imageDir/payment-recovery-$language.png',
            ).writeAsBytes(bytes!.buffer.asUint8List());
          });
        }
        await pump(busy: true);
        expect(
          tester
              .widget<OutlinedButton>(find.byType(OutlinedButton).first)
              .onPressed,
          isNull,
        );
        expect(
          tester.widget<TextButton>(find.byType(TextButton).first).onPressed,
          isNull,
        );
        await pump(count: 100);
        expect(tester.takeException(), isNull);
      },
    );
  }
}
