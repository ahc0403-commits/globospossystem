import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_tracking_link.dart';

void main() {
  test(
    'tracking accepts HTTPS providers and rejects unsafe schemes and credentials',
    () {
      for (final url in [
        'javascript:alert(1)',
        'http://example.com',
        'https://user:pass@example.com',
        'https://example.com:8080',
      ]) {
        expect(directOrderTrackingUri(url), isNull);
      }
      const url = 'https://example.com/track?code=A%2FB&token=ABC';
      expect(directOrderTrackingUri(url)?.toString(), url);
      expect(directOrderTrackingLinks('배송 링크: $url'), [url]);
    },
  );

  for (final throws in [false, true]) {
    testWidgets(
      'failed launch ($throws) retains selectable URL and copy fallback',
      (tester) async {
        const url = 'https://example.com/track?code=A%2FB';
        String? copied;
        await tester.pumpWidget(
          MaterialApp(
            locale: const Locale('ko'),
            supportedLocales: const [Locale('ko')],
            localizationsDelegates: GlobalMaterialLocalizations.delegates,
            home: Scaffold(
              body: DirectOrderTrackingLink(
                url: url,
                opener: (_) async {
                  if (throws) throw StateError('launch failed');
                  return false;
                },
                copier: (value) async {
                  copied = value;
                },
              ),
            ),
          ),
        );
        await tester.tap(find.text('배송 확인'));
        await tester.pumpAndSettle();
        expect(find.textContaining('복사해서 브라우저'), findsOneWidget);
        expect(
          find.byWidgetPredicate(
            (widget) => widget is SelectableText && widget.data == url,
          ),
          findsOneWidget,
        );
        await tester.tap(find.text('링크 복사'));
        await tester.pumpAndSettle();
        expect(copied, url);
      },
    );
  }
  testWidgets('clipboard failure leaves manual selection available', (
    tester,
  ) async {
    const url = 'https://example.com/track';
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ko'),
        supportedLocales: const [Locale('ko')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: Scaffold(
          body: DirectOrderTrackingLink(
            url: url,
            copier: (_) async => throw StateError('denied'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('링크 복사'));
    await tester.pumpAndSettle();
    expect(find.textContaining('길게 눌러 복사'), findsOneWidget);
    expect(find.byType(SelectableText), findsOneWidget);
  });
}
