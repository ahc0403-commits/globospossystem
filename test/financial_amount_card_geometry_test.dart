import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/widgets/financial_amount_cards.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    await (FontLoader(
      AppFonts.family,
    )..addFont(rootBundle.load(AppFonts.assetPath))).load();
  });

  for (final language in ['ko', 'en', 'vi']) {
    for (final width in [390.0, 600.0, 768.0, 1024.0, 1280.0, 1440.0, 1920.0]) {
      for (final scale in [1.0, 1.3, 2.0]) {
        testWidgets('financial row geometry $language $width $scale', (
          tester,
        ) async {
          tester.view.physicalSize = Size(width, 844);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          var clicks = 0;
          final titles = switch (language) {
            'vi' => [
              'Tiền mặt',
              'Doanh thu chuyển khoản của khách tại cửa hàng mẫu',
              'Thẻ',
              'Thanh toán',
            ],
            'en' => [
              'Cash',
              'Customer bank transfers for the sample store',
              'Card',
              'Other payments',
            ],
            _ => ['현금', '샘플 매장의 고객 계좌이체 매출', '카드', '기타 결제'],
          };
          await tester.pumpWidget(
            MaterialApp(
              theme: AppTheme.build(),
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
                    child: FinancialAmountCards(
                      maxColumns: 4,
                      cards: [
                        for (var i = 0; i < 4; i++)
                          FinancialAmountCardData(
                            id: 'sample_$i',
                            title: titles[i],
                            amount: i == 1 ? 999999999999 : 1234567,
                            details: i == 1
                                ? [
                                    'SAMPLE · ${List.filled(4, titles[1]).join(' ')}',
                                  ]
                                : const [],
                            actionLabel: i < 2 ? 'SAMPLE ${titles[i]}' : null,
                            onAction: i < 2 ? () => clicks++ : null,
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final rows = <double, List<int>>{};
          final cards = <Rect>[];
          for (var i = 0; i < 4; i++) {
            final rect = tester.getRect(find.byKey(ValueKey('sample_$i')));
            cards.add(rect);
            final row = rows.keys.where((y) => (y - rect.top).abs() < .5);
            rows
                .putIfAbsent(row.isEmpty ? rect.top : row.first, () => [])
                .add(i);
            expect(rect.left, greaterThanOrEqualTo(0));
            expect(rect.right, lessThanOrEqualTo(width));
            final amount = tester.widget<Text>(
              find.byKey(ValueKey('sample_${i}_amount')),
            );
            expect(amount.overflow, isNot(TextOverflow.ellipsis));
          }
          for (final indices in rows.values) {
            final first = indices.first;
            final amountY = tester
                .getTopLeft(find.byKey(ValueKey('sample_${first}_amount')))
                .dy;
            final actionBottoms = <double>[];
            for (final i in indices) {
              expect(cards[i].height, closeTo(cards[first].height, .5));
              expect(
                tester
                    .getTopLeft(find.byKey(ValueKey('sample_${i}_amount')))
                    .dy,
                closeTo(amountY, .5),
              );
              final action = find.descendant(
                of: find.byKey(ValueKey('sample_$i')),
                matching: find.byType(TextButton),
              );
              if (action.evaluate().isNotEmpty) {
                actionBottoms.add(tester.getBottomRight(action).dy);
              }
            }
            if (actionBottoms.length > 1) {
              expect(actionBottoms.last, closeTo(actionBottoms.first, .5));
            }
          }
          if (scale >= 1.3 || width < 600) expect(rows.length, 4);
          for (var i = 0; i < 2; i++) {
            final action = find.descendant(
              of: find.byKey(ValueKey('sample_$i')),
              matching: find.byType(TextButton),
            );
            await tester.ensureVisible(action);
            await tester.tap(action);
            await tester.pump();
          }
          expect(clicks, 2);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
}
