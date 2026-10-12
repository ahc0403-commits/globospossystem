import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/daily_sales_report_service.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'daily_sales_report_service_test.dart' as fixtures;

void main() {
  testWidgets(
    'multiple stores choose a closing without changing selected entity',
    (tester) async {
      Map<String, dynamic>? bankScope;
      final service = DailySalesReportService(
        rpc: (name, p) async {
          if (name == 'get_bank_transfer_sales_page') {
            bankScope = p;
            return {
              'from_date': p['p_from_date'],
              'to_date': p['p_to_date'],
              'tax_entity_id': p['p_tax_entity_id'],
              'store_id': p['p_store_id'],
              'rows': <dynamic>[],
              'has_more': false,
            };
          }
          return {
            'business_date': p['p_business_date'],
            'entities': [
              fixtures.row()
                ..['bunsik_stores'] = [
                  {'store_id': 'store-a', 'store_name': 'Store A'},
                  {'store_id': 'store-b', 'store_name': 'Store B'},
                ],
            ],
          };
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: RestaurantSalesExportScreen(
              embedded: true,
              initialBusinessDate: '2026-10-08',
              reportService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final closing = find.text('Review daily closing');
      await tester.ensureVisible(closing);
      await tester.pumpAndSettle();
      await tester.tap(closing);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('sales_deposit_store_dialog')),
        findsOneWidget,
      );
      expect(find.text('Store A'), findsOneWidget);
      expect(find.text('Store B'), findsOneWidget);
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('sales_deposit_store_dialog')), findsNothing);
      final bank = find.text('View bank transfers');
      await tester.ensureVisible(bank);
      await tester.pumpAndSettle();
      await tester.tap(bank);
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('bank_transfer_ledger_dialog')),
        findsOneWidget,
      );
      expect(bankScope?['p_tax_entity_id'], 'entity');
      expect(bankScope?['p_from_date'], '2026-10-08');
      expect(bankScope?['p_limit'], 100);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'mapping dialog opens, requires selected JSON and closes without writes',
    (tester) async {
      final calls = <String>[];
      final service = DailySalesReportService(
        rpc: (name, p) async {
          calls.add(name);
          return {
            'business_date': p['p_business_date'],
            'entities': [fixtures.row()],
          };
        },
      );
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: RestaurantSalesExportScreen(
              embedded: true,
              todayOverride: DateTime(2026, 10, 8),
              reportService: service,
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final open = find.text('Approve invoice mappings');
      await tester.ensureVisible(open);
      await tester.pumpAndSettle();
      await tester.tap(open);
      await tester.pumpAndSettle();
      expect(find.text('Choose mapping JSON'), findsOneWidget);
      final approve = find.widgetWithText(
        FilledButton,
        'Approve reviewed mappings',
      );
      expect(tester.widget<FilledButton>(approve).onPressed, isNull);
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Choose mapping JSON'), findsNothing);
      expect(calls, ['get_pos_daily_sales_summary']);
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
