import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/daily_sales_report_service.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'daily_sales_report_service_test.dart' as fixtures;

void main() {
  testWidgets('visible summary refreshes in 30s and pauses in background', (
    tester,
  ) async {
    var calls = 0;
    final service = DailySalesReportService(
      rpc: (name, p) async {
        calls++;
        expect(p['p_include_export_metadata'], isFalse);
        return {
          'business_date': p['p_business_date'],
          'entities': [fixtures.row()],
        };
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ko'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RestaurantSalesExportScreen(
            embedded: true,
            reportService: service,
            todayOverride: DateTime(2026, 10, 8),
            summaryRefreshInterval: const Duration(seconds: 30),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, 1);
    await tester.pump(const Duration(seconds: 30));
    await tester.pumpAndSettle();
    expect(calls, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await tester.pump(const Duration(seconds: 31));
    expect(calls, 2);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(calls, 3);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 31));
    expect(calls, 3);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'bank_transfer_ledger_dialog and sales_deposit_store_dialog retain selected scope',
    (tester) async {
      var bankCalls = 0;
      final service = DailySalesReportService(
        rpc: (name, p) async {
          if (name == 'get_bank_transfer_sales_page') {
            bankCalls++;
            expect(p['p_tax_entity_id'], 'entity');
            expect(p['p_from_date'], '2026-10-08');
            return {
              'from_date': p['p_from_date'],
              'to_date': p['p_to_date'],
              'tax_entity_id': p['p_tax_entity_id'],
              'store_id': null,
              'rows': [],
              'has_more': false,
            };
          }
          return {
            'business_date': p['p_business_date'],
            'entities': [
              fixtures.row()..addAll({
                'bunsik_store_count': 2,
                'bunsik_stores': [
                  {'store_id': 'first', 'store_name': 'First Bunsik'},
                  {'store_id': 'second', 'store_name': 'Second Bunsik'},
                ],
              }),
            ],
          };
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ko'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: RestaurantSalesExportScreen(
              embedded: true,
              reportService: service,
              todayOverride: DateTime(2026, 10, 8),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('계좌이체 내역 보기'));
      await tester.tap(find.text('계좌이체 내역 보기'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('bank_transfer_ledger_dialog')),
        findsOneWidget,
      );
      expect(bankCalls, 1);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.text('마감 내역 확인'));
      await tester.tap(find.text('마감 내역 확인'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('sales_deposit_store_dialog')),
        findsOneWidget,
      );
      expect(find.text('First Bunsik'), findsOneWidget);
      expect(find.text('Second Bunsik'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      final mappings = find.text('계산서 매핑 일괄 승인');
      await tester.ensureVisible(mappings);
      await tester.tap(mappings);
      await tester.pumpAndSettle();
      expect(find.text('매핑 JSON 선택'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'download rejects all invalid items before save and shows source identities',
    (tester) async {
      var saved = 0;
      final service = DailySalesReportService(
        rpc: (name, p) async {
          if (name == 'get_pos_daily_sales_summary') {
            return {
              'business_date': p['p_business_date'],
              'entities': [
                fixtures.row()..addAll({
                  'restaurant_receipt_count': 1,
                  'restaurant_gross': 10800,
                  'photo_receipt_count': 0,
                  'photo_gross': 0,
                }),
              ],
            };
          }
          final r = fixtures.receipt(1)
            ..['sold_at'] = '${p['p_business_date']}T12:00:00+07:00';
          (r['line_items'] as List).first.remove('quantity');
          return {
            'business_date': p['p_business_date'],
            'tax_entity_id': 'entity',
            'source_system': 'restaurant_pos',
            'rows': [r],
          };
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ko'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: RestaurantSalesExportScreen(
              embedded: true,
              todayOverride: DateTime(2026, 10, 8),
              reportService: service,
              saveFile: (_, bytes) async {
                saved++;
              },
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final button = find.byKey(const Key('restaurant_sales_export_button'));
      await tester.ensureVisible(button);
      await tester.pumpAndSettle();
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(saved, 0);
      expect(find.byType(AlertDialog), findsOneWidget);
      expect(find.textContaining('line-1'), findsWidgets);
      expect(find.textContaining('quantity'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('sales_collection_bank_dialog saves only selected legal entity', (
    tester,
  ) async {
    Map<String, dynamic>? saved;
    final service = DailySalesReportService(
      rpc: (name, p) async => {
        'business_date': p['p_business_date'],
        'entities': [
          fixtures.row()
            ..['bank'] = {
              'bin': '970426',
              'label': 'MSB',
              'account_number': '80002014298',
              'account_holder': 'AKJ INTERNATIONAL CO., LTD',
            },
        ],
      },
    );
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ko'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: RestaurantSalesExportScreen(
            embedded: true,
            todayOverride: DateTime(2026, 10, 8),
            reportService: service,
            saveCollectionBank: (p) async => saved = p,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('308.000 VND'), findsOneWidget);
    final button = find.text('법인 수금 계좌 설정');
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('sales_collection_bank_dialog')),
      findsOneWidget,
    );
    final account = find.widgetWithText(TextField, '80002014298');
    await tester.enterText(account, '80002014299');
    await tester.tap(find.text('저장'));
    await tester.pumpAndSettle();
    expect(saved?['p_tax_entity_id'], 'entity');
    expect(saved?['p_account'], '80002014299');
    expect(find.byKey(const Key('sales_collection_bank_dialog')), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
