import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/admin/providers/daily_closing_provider.dart';
import 'package:globos_pos_system/features/admin/tabs/reports_tab.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

const _storeId = '00000000-0000-0000-0000-000000000001';

DailyClosingRecord _record({bool closed = false}) {
  return DailyClosingRecord(
    id: 'closing-1',
    closingDate: '2026-08-13',
    closedByName: '긴 이름을 가진 마감 담당자',
    ordersTotal: 38,
    ordersCompleted: 31,
    ordersCancelled: 7,
    itemsCancelled: 7,
    paymentsCount: 31,
    paymentsTotal: 123456789,
    paymentsCash: 23456789,
    paymentsCard: 50000000,
    paymentsPay: 30000000,
    paymentsBankTransfer: 20000000,
    openingCashAmount: 5000000,
    expectedCashAmount: 28456789,
    countedCashAmount: 28456789,
    cashVariance: 0,
    serviceCount: 0,
    serviceTotal: 0,
    lowStockCount: 0,
    closeSource: closed ? 'manual' : 'scheduled',
    createdAt: DateTime(2026, 8, 13),
  );
}

Widget _app(Widget home, {double textScale = 1}) {
  return ProviderScope(
    overrides: [
      dailyClosingHistoryProvider.overrideWith(
        (ref, storeId) async => [_record()],
      ),
    ],
    child: MaterialApp(
      locale: const Locale('ko'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: home,
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('phone launcher opens the dedicated daily closing screen', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(
        const Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(12),
            child: DailyClosingLauncher(storeId: _storeId),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('daily_closing_launcher')), findsOneWidget);
    expect(find.byKey(const Key('daily_closing_open_screen')), findsOneWidget);
    expect(find.byKey(const Key('daily_closing_cards')), findsNothing);

    await tester.tap(find.byKey(const Key('daily_closing_open_screen')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('daily_closing_screen')), findsOneWidget);
    expect(find.byKey(const Key('daily_closing_cards')), findsOneWidget);
    expect(
      find.byKey(const Key('daily_closing_card_2026-08-13')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);

    await tester.tap(find.byType(BackButton));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('daily_closing_launcher')), findsOneWidget);
  });

  for (final size in const [Size(768, 1024), Size(1024, 768)]) {
    testWidgets('tablet $size keeps every daily closing metric readable', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(const DailyClosingScreen(storeId: _storeId)),
      );
      await tester.pumpAndSettle();

      expect(find.byKey(const Key('daily_closing_cards')), findsOneWidget);
      expect(find.text('123.456.789 VND'), findsOneWidget);
      expect(find.text('23.456.789 VND'), findsOneWidget);
      expect(find.text('50.000.000 VND'), findsOneWidget);
      expect(find.text('30.000.000 VND'), findsOneWidget);
      expect(find.text('20.000.000 VND'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('wide presentation preserves the existing inline table', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1440, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(const Scaffold(body: DailyClosingSection(storeId: _storeId))),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('nav_daily_closing')), findsOneWidget);
    expect(find.byKey(const Key('daily_closing_cards')), findsNothing);
    expect(
      find.byKey(const Key('daily_closing_action_2026-08-13')),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('phone cards remain scrollable at 200 percent text scale', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      _app(const DailyClosingScreen(storeId: _storeId), textScale: 2),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('daily_closing_screen_scroll')),
      findsOneWidget,
    );
    expect(find.text('123.456.789 VND'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
