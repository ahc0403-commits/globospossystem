import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

void main() {
  testWidgets('SAMPLE-only sales cannot be selected or downloaded', (
    tester,
  ) async {
    var saved = false;
    await tester.pumpWidget(
      _app(
        RestaurantSalesExportScreen(
          embedded: true,
          loader: (_) async => [_export(sample: true)],
          saveFile: (_, _) async => saved = true,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('BunsikClub SAMPLE'), findsNothing);
    expect(find.byType(DropdownButtonFormField<String>), findsNothing);
    expect(
      find.text('There are no Restaurant or Photo sales for this date.'),
      findsOneWidget,
    );
    final button = find.byKey(const Key('restaurant_sales_export_button'));
    expect(tester.widget<ButtonStyleButton>(button).onPressed, isNull);
    expect(saved, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('mixed sales expose and download only the production entity', (
    tester,
  ) async {
    List<int>? savedBytes;
    await tester.pumpWidget(
      _app(
        RestaurantSalesExportScreen(
          embedded: true,
          todayOverride: DateTime.parse('2026-10-05T12:00:00+07:00'),
          loader: (_) async => [_export(sample: true), _export(sample: false)],
          saveFile: (_, bytes) async => savedBytes = bytes,
        ),
      ),
    );
    await tester.pumpAndSettle();

    final selector = tester.widget<DropdownButton<String>>(
      find.byType(DropdownButton<String>),
    );
    expect(selector.items!.map((item) => item.value), ['production-entity']);
    final button = find.byKey(const Key('restaurant_sales_export_button'));
    await tester.ensureVisible(button);
    await tester.pumpAndSettle();
    await tester.tap(button);
    await tester.pumpAndSettle();

    final rows = Excel.decodeBytes(savedBytes!).tables['Hóa đơn GTGT']!.rows;
    expect(rows, hasLength(9));
    expect(rows[8][14]!.value.toString(), '100000');
    expect(rows[8][16]!.value.toString(), '8000');
    expect(tester.takeException(), isNull);
  });
}

Widget _app(Widget child) => MaterialApp(
  locale: const Locale('en'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: Scaffold(body: child),
);

RestaurantSalesExport _export({required bool sample}) => RestaurantSalesExport(
  businessDate: '2026-10-05',
  taxEntityId: sample ? 'sample-entity' : 'production-entity',
  sellerTaxCode: sample ? 'PENDING_SAMPLE_STORE_TAX_PROFILE' : '0318453298',
  sellerLegalName: sample ? 'BunsikClub SAMPLE' : 'AKJ INTERNATIONAL',
  isSampleEntity: sample,
  storeCount: 1,
  receiptCount: 1,
  grossSales: sample ? 189000 : 108000,
  finalizedAt: null,
  receipts: [
    RestaurantSalesReceipt(
      storeId: sample ? 'sample-store' : 'production-store',
      storeName: sample ? 'BunsikClub SAMPLE' : 'BunsikClub Production',
      receiptId: sample ? 'sample-receipt' : 'production-receipt',
      receiptSource: 'pos_payment',
      salesChannel: 'dine_in',
      grossSales: sample ? 189000 : 108000,
      soldAt: DateTime.parse('2026-10-05T10:00:00+07:00'),
      paymentMethod: 'TM',
      isRedInvoice: false,
      buyerTaxCode: '',
      buyerLegalName: '',
      buyerAddress: '',
      buyerEmail: '',
      buyerPhone: '',
      lineItems: [
        RestaurantSalesLineItem(
          name: 'Food',
          quantity: 1,
          unitPrice: sample ? 175000 : 100000,
          supplyAmount: sample ? 175000 : 100000,
          vatRate: 8,
          vatAmount: sample ? 14000 : 8000,
        ),
      ],
      issues: const [],
    ),
  ],
);
