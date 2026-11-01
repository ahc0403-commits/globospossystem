import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_translation.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

const _translationHelp = {
  'ko': '서로 다른 언어로 대화해도 메시지가 자동 번역됩니다. 편하게 채팅하세요!',
  'vi':
      'Tin nhắn được tự động dịch khi trò chuyện bằng các ngôn ngữ khác nhau. Hãy thoải mái trò chuyện!',
  'en':
      'Messages are automatically translated across languages. Feel free to chat!',
};

void main() {
  for (final locale in ['ko', 'en', 'vi']) {
    for (final width in [390.0, 1440.0]) {
      testWidgets('translation help is separate UI in $locale at $width', (
        tester,
      ) async {
        tester.view.physicalSize = Size(width, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pumpWidget(
          MaterialApp(
            locale: Locale(locale),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            home: Scaffold(
              body: Builder(
                builder: (context) => Column(
                  children: [
                    directOrderAutomaticTranslationNotice(context),
                    const DirectOrderTranslatedText(
                      original: 'Original chat message',
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(
          directOrderAutomaticTranslationHelp(locale),
          _translationHelp[locale],
        );
        final notice = find.byKey(const Key('direct_auto_translation_notice'));
        expect(notice, findsOneWidget);
        expect(find.text(_translationHelp[locale]!), findsOneWidget);
        expect(find.byType(DirectOrderTranslatedText), findsOneWidget);
        expect(
          find.descendant(
            of: notice,
            matching: find.byType(DirectOrderTranslatedText),
          ),
          findsNothing,
        );
        expect(find.text('Original chat message'), findsOneWidget);
        expect(
          tester.getBottomLeft(notice).dy,
          lessThanOrEqualTo(
            tester.getTopLeft(find.byType(DirectOrderTranslatedText)).dy,
          ),
        );
        expect(tester.takeException(), isNull);
      });
    }
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
