import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/vietqr_bank_link.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_bank_handoff.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';

void main() {
  setUpAll(() async {
    if (Platform.environment['DIRECT_ORDER_BANK_SCREENSHOTS'] == null) return;
    final text = FontLoader('Pretendard')
      ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf'));
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await Future.wait([text.load(), icons.load()]);
  });
  final returnUri = VietQrBankLink.safeReturnUri(
    Uri.parse(
      'https://shop.test/?secret=hidden#/order/store/r/id?access=hidden',
    ),
    'bunsik',
  )!;
  test(
    'bank handoff carries only quoted transfer data with a credential-free return',
    () {
      expect(returnUri.toString(), 'https://shop.test/#/order/bunsik');
      for (final app in VietQrBankLink.apps.keys) {
        final uri = VietQrBankLink.build(
          app: app,
          bankBin: '970426',
          accountNumber: '80002014298',
          accountHolder: 'AKJ INTERNATIONAL CO., LTD',
          amount: 273240,
          reference: 'D12345678',
          returnUri: returnUri,
        );
        expect(uri.origin, 'https://dl.vietqr.io');
        expect(uri.path, '/pay');
        expect(uri.queryParameters, {
          'app': app,
          'ba': '80002014298@msb',
          'am': '273240',
          'tn': 'D12345678',
          'bn': 'AKJ INTERNATIONAL CO., LTD',
          'url': 'https://shop.test/#/order/bunsik',
        });
        expect(uri.toString(), isNot(contains('hidden')));
      }
    },
  );
  test(
    'invalid targets amounts apps and credential return paths are rejected',
    () {
      Uri build({
        String app = 'mb',
        String bank = '970426',
        int amount = 1,
        String account = '80002014298',
        Uri? url,
      }) => VietQrBankLink.build(
        app: app,
        bankBin: bank,
        amount: amount,
        accountNumber: account,
        accountHolder: 'Fixture',
        reference: 'D12345678',
        returnUri: url ?? returnUri,
      );
      expect(() => build(app: 'unsupported'), throwsArgumentError);
      expect(() => build(bank: '000000'), throwsArgumentError);
      expect(() => build(amount: 0), throwsArgumentError);
      expect(() => build(amount: -100), throwsArgumentError);
      expect(() => build(account: '123@other'), throwsArgumentError);
      expect(
        () => build(
          url: Uri.parse('https://shop.test/?access=hidden#/order/bunsik'),
        ),
        throwsArgumentError,
      );
      expect(
        VietQrBankLink.safeReturnUri(
          Uri.parse('file:///private/path'),
          'bunsik',
        ),
        isNull,
      );
    },
  );
  for (final opened in [true, false]) {
    testWidgets(
      'bank selection launches one exact transfer and handles opened=$opened at 320px',
      (tester) async {
        tester.view.physicalSize = const Size(320, 760);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final launched = <Uri>[];
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(fontFamily: 'Pretendard'),
            home: Scaffold(
              body: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: RepaintBoundary(
                    key: const Key('bank_visual'),
                    child: ColoredBox(
                      color: Colors.white,
                      child: DirectOrderBankHandoff(
                        bank: const DirectOrderBank(
                          bin: '970426',
                          accountNumber: '80002014298',
                          accountHolder: 'Fixture',
                          label: 'MSB',
                        ),
                        amount: 273240,
                        reference: 'D12345678',
                        returnUri: returnUri,
                        launcher: (uri) async {
                          launched.add(uri);
                          return opened;
                        },
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('direct_open_bank_app')),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.byKey(const Key('direct_bank_app')));
        await tester.pumpAndSettle();
        await tester.tap(find.text('MBBank').last);
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('direct_open_bank_app')));
        await tester.pumpAndSettle();
        expect(launched.single.queryParameters['am'], '273240');
        expect(launched.single.queryParameters['ba'], '80002014298@msb');
        expect(
          find.textContaining(
            opened ? 'Check the recipient' : 'If the app does not open',
          ),
          findsOneWidget,
        );
        expect(tester.takeException(), isNull);
        final directory = Platform.environment['DIRECT_ORDER_BANK_SCREENSHOTS'];
        if (directory != null) {
          final boundary = tester.renderObject<RenderRepaintBoundary>(
            find.byKey(const Key('bank_visual')),
          );
          await tester.runAsync(() async {
            final image = await boundary.toImage(pixelRatio: 2);
            final data = await image.toByteData(format: ui.ImageByteFormat.png);
            await Directory(directory).create(recursive: true);
            await File(
              '$directory/bank-handoff-$opened.png',
            ).writeAsBytes(data!.buffer.asUint8List());
            image.dispose();
          });
        }
      },
    );
  }
}
