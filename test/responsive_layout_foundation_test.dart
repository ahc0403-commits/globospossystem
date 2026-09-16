import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/i18n/locale_extensions.dart';
import 'package:globos_pos_system/core/layout/adaptive_layout.dart';
import 'package:globos_pos_system/core/ui/toast/toast.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

Widget _localizedApp({
  required Locale locale,
  required Widget child,
  double textScale = 1,
}) {
  return MaterialApp(
    locale: locale,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    builder: (context, child) => MediaQuery(
      data: MediaQuery.of(
        context,
      ).copyWith(textScaler: TextScaler.linear(textScale)),
      child: child!,
    ),
    home: child,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('canonical POS window classes have stable boundaries', () {
    expect(
      PosLayoutSpec.fromWidth(width: 599).windowClass,
      PosWindowClass.compact,
    );
    expect(
      PosLayoutSpec.fromWidth(width: 600).windowClass,
      PosWindowClass.medium,
    );
    expect(
      PosLayoutSpec.fromWidth(width: 1023).windowClass,
      PosWindowClass.medium,
    );
    expect(
      PosLayoutSpec.fromWidth(width: 1024).windowClass,
      PosWindowClass.wide,
    );
    expect(
      PosLayoutSpec.fromWidth(width: 1440).windowClass,
      PosWindowClass.large,
    );
    expect(
      PosLayoutSpec.fromWidth(width: 1600, textScale: 1.3).prefersSingleColumn,
      isTrue,
    );
    expect(
      PosLayoutSpec.fromWidth(width: 844, height: 390).prefersCompactShell,
      isTrue,
    );
  });

  testWidgets('adaptive layout follows width even on desktop test hosts', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      const MaterialApp(
        home: MediaQuery(
          data: MediaQueryData(size: Size(390, 844)),
          child: AdaptiveLayout(
            mobileLayout: Text('mobile'),
            desktopLayout: Text('desktop'),
          ),
        ),
      ),
    );

    expect(find.text('mobile'), findsOneWidget);
    expect(find.text('desktop'), findsNothing);
  });

  for (final locale in const [Locale('ko'), Locale('en'), Locale('vi')]) {
    for (final size in const [
      Size(390, 844),
      Size(768, 1024),
      Size(1024, 768),
      Size(1440, 900),
    ]) {
      testWidgets(
        '${locale.languageCode} $size keeps shared dense UI readable',
        (tester) async {
          await tester.binding.setSurfaceSize(size);
          addTearDown(() => tester.binding.setSurfaceSize(null));
          await tester.pumpWidget(
            _localizedApp(
              locale: locale,
              child: Builder(
                builder: (context) => Scaffold(
                  body: ToastResponsiveScrollBody(
                    children: [
                      PosPageHeader(
                        title: context.l10n.reportsDailySalesTitle,
                        subtitle: context.l10n.reportsDailySalesSubtitle,
                        trailing: PosActionButton(
                          label: context.l10n.reportsDownload,
                          tone: PosActionTone.primary,
                          icon: Icons.download,
                          onPressed: () {},
                        ),
                      ),
                      ToastMetricStrip(
                        dense: true,
                        metrics: [
                          ToastMetric(
                            label: context.l10n.settingsPermissionGroups,
                            value: '6',
                          ),
                          ToastMetric(
                            label: context.l10n.settingsPaymentConfig,
                            value: '123.456.789 VND',
                          ),
                          ToastMetric(
                            label: context.l10n.reportsDailySalesTitle,
                            value: '5.523.660 VND',
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();

          expect(find.text(contextFreeTitle(locale)), findsWidgets);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('Vietnamese compact layout remains operable at 200% text', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _localizedApp(
        locale: const Locale('vi'),
        textScale: 2,
        child: Builder(
          builder: (context) => Scaffold(
            body: ToastResponsiveScrollBody(
              children: [
                PosPageHeader(
                  title: context.l10n.reportsDailySalesTitle,
                  subtitle: context.l10n.reportsDailySalesSubtitle,
                  trailing: PosActionButton(
                    label: context.l10n.reportsDownload,
                    tone: PosActionTone.primary,
                    onPressed: () {},
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Tải xuống'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

String contextFreeTitle(Locale locale) => switch (locale.languageCode) {
  'en' => 'Daily sales',
  'vi' => 'Doanh thu theo ngày',
  _ => '일별 매출',
};
