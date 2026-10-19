import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_translation.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

void main() {
  for (final locale in ['ko', 'en', 'vi']) {
    testWidgets(
      'translation preserves the original and follows viewer locale $locale',
      (tester) async {
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(
              body: DirectOrderTranslatedText(
                original: '양파 빼 주세요. 10,000 VND',
                translations: {
                  'vi': 'Không hành tây. 10,000 VND',
                  'en': 'No onions. 10,000 VND',
                },
                status: 'translated',
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        if (locale == 'ko') {
          expect(find.text('양파 빼 주세요. 10,000 VND'), findsOneWidget);
          expect(find.byType(TextButton), findsNothing);
        } else {
          expect(
            find.text(
              locale == 'vi'
                  ? 'Không hành tây. 10,000 VND'
                  : 'No onions. 10,000 VND',
            ),
            findsOneWidget,
          );
          expect(find.text('양파 빼 주세요. 10,000 VND'), findsNothing);
          await tester.tap(find.byType(TextButton));
          await tester.pump();
          expect(find.text('양파 빼 주세요. 10,000 VND'), findsOneWidget);
        }
      },
    );
  }
  testWidgets('failed translation leaves the original visible', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: DirectOrderTranslatedText(
            original: 'No peanuts',
            status: 'failed',
          ),
        ),
      ),
    );
    expect(find.text('No peanuts'), findsOneWidget);
    expect(
      find.text('Translation unavailable; showing original.'),
      findsOneWidget,
    );
  });
}
