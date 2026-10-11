import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/daily_sales_report_service.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'daily_sales_report_service_test.dart' as fixtures;

void main() {
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
    expect(find.text('308.000 ₫'), findsOneWidget);
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
