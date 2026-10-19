import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:globos_pos_system/features/red_invoice_intake/buyer_number.dart';
import 'package:globos_pos_system/core/services/company_tax_lookup_service.dart';
import 'package:globos_pos_system/features/red_invoice_intake/buyer_information_form.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/pos_receipt_ledger.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/pos_receipt_ledger_service.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

Map<String, dynamic> buyer({String number = '0012345678'}) => {
  'id': 'intake',
  'buyer_version': 3,
  'status': 'ready',
  'buyer_number_type': 'vn_tax',
  'buyer_number_value': number,
  'buyer_tax_code': number,
  'buyer_legal_name': 'Company',
  'buyer_full_name': 'Buyer',
  'buyer_address': 'Address',
  'buyer_email': 'buyer@example.invalid',
  'buyer_phone': '0900000000',
  'buyer_email_cc': 'cc@example.invalid',
  'buyer_unit_code': 'UNIT',
  'buyer_id': '001234567890',
  'source_note': 'Keep note',
  'attachment_urls': ['https://fixture.invalid/evidence'],
};
Widget app(Widget home, {String locale = 'en'}) => MaterialApp(
  theme: ThemeData(fontFamily: 'LedgerPreview'),
  locale: Locale(locale),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: home,
);
void main() {
  test(
    'format validation preserves zeroes and separates domestic and foreign types',
    () {
      for (final value in ['0012345678', '0012345678-001', '0012345678-999']) {
        expect(validateBuyerNumber(BuyerNumberType.vnTax, value), isNull);
      }
      for (final value in [
        '123456789',
        '12345678901',
        '1234567890-000',
        '1234567890-01',
        '1234567890-001-002',
        '123456789x',
      ]) {
        expect(validateBuyerNumber(BuyerNumberType.vnTax, value), isNotNull);
      }
      for (final type in [
        BuyerNumberType.household,
        BuyerNumberType.personal,
      ]) {
        expect(validateBuyerNumber(type, '001234567890'), isNull);
        expect(
          validateBuyerNumber(type, '00123456789')?.code,
          'identity_length',
        );
        expect(validateBuyerNumber(type, '00123456789a')?.code, 'digits');
      }
      expect(
        validateBuyerNumber(BuyerNumberType.foreignTax, 'DE-0012345'),
        isNull,
      );
      expect(
        validateBuyerNumber(BuyerNumberType.passport, 'A00123456'),
        isNull,
      );
      final diagnostic = validateBuyerNumber(
        BuyerNumberType.vnTax,
        '00123456789-12',
      )!;
      expect(diagnostic.left, 11);
      expect(diagnostic.right, 2);
      for (final locale in ['ko', 'vi', 'en']) {
        expect(BuyerNumberCopy(locale).error(diagnostic), contains('11'));
        expect(BuyerNumberCopy(locale).error(diagnostic), contains('2'));
      }
    },
  );
  test(
    'page deduplicates requests, expires and scopes cache to login',
    () async {
      var calls = 0;
      var session = 'one';
      var clock = DateTime.utc(2026);
      final gate = Completer<void>();
      final service = PosReceiptLedgerService(
        sessionScope: () => session,
        clock: () => clock,
        rpc: (name, params) async {
          calls++;
          if (calls == 1) await gate.future;
          return {
            'rows': [
              (params['p_order_ids'] as List)
                  .map((id) => {'order_id': id, 'buyer': buyer()})
                  .first,
            ],
          };
        },
      );
      final first = service.page(
        day: '2026-09-04',
        entity: 'entity',
        red: true,
        orderIds: ['order'],
      );
      final duplicate = service.page(
        day: '2026-09-04',
        entity: 'entity',
        red: true,
        orderIds: ['order'],
      );
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      gate.complete();
      await Future.wait([first, duplicate]);
      await service.page(
        day: '2026-09-04',
        entity: 'entity',
        red: true,
        orderIds: ['order'],
      );
      expect(calls, 1);
      clock = clock.add(const Duration(seconds: 61));
      await service.page(
        day: '2026-09-04',
        entity: 'entity',
        red: true,
        orderIds: ['order'],
      );
      expect(calls, 2);
      session = 'two';
      await service.page(
        day: '2026-09-04',
        entity: 'entity',
        red: true,
        orderIds: ['order'],
      );
      expect(calls, 3);
      expect(
        () => service.page(
          day: '2026-09-04',
          entity: 'entity',
          red: true,
          orderIds: List.generate(51, (i) => '$i'),
        ),
        throwsArgumentError,
      );
    },
  );
  for (final locale in ['ko', 'vi', 'en']) {
    testWidgets(
      '$locale invalid number is shown under field, retained and focused',
      (tester) async {
        tester.view.physicalSize = const Size(1200, 1400);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final c = BuyerInformationController(buyer(number: '00123456789-12'));
        addTearDown(c.dispose);
        await tester.pumpWidget(
          app(
            Scaffold(
              body: SingleChildScrollView(
                child: BuyerInformationFields(controller: c),
              ),
            ),
            locale: locale,
          ),
        );
        expect(c.validate(), isFalse);
        await tester.pump();
        expect(
          find.text(
            BuyerNumberCopy(locale).error(
              const BuyerNumberIssue('branch_length', left: 11, right: 2),
            ),
          ),
          findsOneWidget,
        );
        expect(c.numberFocus.hasFocus, isTrue);
        expect(c.fields['buyer_number_value']!.text, '00123456789-12');
        await tester.enterText(
          find.byKey(const Key('pos_buyer_number_value')),
          '0012345678-001',
        );
        expect(c.validate(), isTrue);
        expect(c.patch['buyer_email_cc'], 'cc@example.invalid');
        expect(c.patch['buyer_unit_code'], 'UNIT');
      },
    );
  }
  testWidgets(
    'cancel never saves; save failure and stale record keep all entries',
    (tester) async {
      tester.view.physicalSize = const Size(1200, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var calls = 0;
      await tester.pumpWidget(
        app(
          Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () => showBuyerInformationDialog(
                  context,
                  initial: buyer(),
                  onSave: (patch) async {
                    calls++;
                    throw const PostgrestException(
                      message: 'POS_BUYER_CHANGED',
                    );
                  },
                ),
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('pos_buyer_save')));
      await tester.pumpAndSettle();
      expect(calls, 1);
      expect(
        find.text(
          'Another employee changed this information. Close and reload the latest record.',
        ),
        findsOneWidget,
      );
      final field = tester.widget<TextFormField>(
        find.byKey(const Key('pos_buyer_email_cc')),
      );
      expect(field.controller!.text, 'cc@example.invalid');
      await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(calls, 1);
    },
  );
  testWidgets('mobile ledger opens from selected report scope', (tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    var calls = 0;
    final service = PosReceiptLedgerService(
      sessionScope: () => 'fixture',
      rpc: (name, params) async {
        calls++;
        return {'rows': []};
      },
    );
    const export = RestaurantSalesExport(
      businessDate: '2026-09-04',
      taxEntityId: 'entity',
      sellerTaxCode: 'tax',
      sellerLegalName: 'Fixture seller',
      isSampleEntity: false,
      storeCount: 0,
      receiptCount: 0,
      grossSales: 0,
      finalizedAt: null,
      receipts: [],
    );
    await tester.pumpWidget(
      app(
        Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showPosReceiptLedger(
                context,
                export: export,
                red: false,
                service: service,
                lookupService: CompanyTaxLookupService(
                  transport: (_, _) async => {'outcome': 'unavailable'},
                  sessionScope: () => 'fixture-session',
                ),
              ),
              child: const Text('Open ledger'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open ledger'));
    await tester.pumpAndSettle();
    expect(find.text('General receipt ledger'), findsOneWidget);
    expect(find.textContaining('2026-09-04'), findsOneWidget);
    expect(find.byType(Dialog), findsOneWidget);
    expect(calls, 0);
    expect(tester.takeException(), isNull);
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();
    expect(find.text('General receipt ledger'), findsNothing);
  });
  testWidgets(
    'ledger reuses counts, detail needs no RPC, save updates one cached row',
    (tester) async {
      tester.view.physicalSize = const Size(1400, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      var reads = 0;
      var writes = 0;
      final service = PosReceiptLedgerService(
        sessionScope: () => 'fixture',
        rpc: (name, params) async {
          if (name == 'pos_receipt_ledger_batch') {
            reads++;
            return {
              'rows': [
                {
                  'order_id': 'order',
                  'payments': [
                    {
                      'payment_id': 'payment-1',
                      'method': 'CASH',
                      'amount': 108,
                      'paid_at': '2026-09-04T05:00Z',
                    },
                  ],
                  'buyer': buyer(number: '00123456789-12'),
                },
              ],
            };
          }
          writes++;
          expect(params['p_expected_version'], 3);
          expect(
            (params['p_patch'] as Map)['buyer_email_cc'],
            'cc@example.invalid',
          );
          return {...buyer(number: '0012345678-001'), 'buyer_version': 4};
        },
      );
      final export = RestaurantSalesExport(
        businessDate: '2026-09-04',
        taxEntityId: 'entity',
        sellerTaxCode: 'tax',
        sellerLegalName: 'Fixture seller',
        isSampleEntity: false,
        storeCount: 1,
        receiptCount: 1,
        grossSales: 108,
        finalizedAt: null,
        receipts: [
          RestaurantSalesReceipt(
            storeId: 'store',
            storeName: 'Fixture restaurant',
            receiptId: 'order',
            receiptNumber: 'BC-20260904-000001',
            receiptSource: 'pos_payment',
            salesChannel: 'dine_in',
            grossSales: 108,
            soldAt: DateTime.utc(2026, 9, 4, 5),
            paymentMethod: 'CASH',
            isRedInvoice: true,
            buyerTaxCode: '00123456789-12',
            buyerLegalName: 'Company',
            buyerAddress: 'Address',
            buyerEmail: 'buyer@example.invalid',
            buyerPhone: '0900000000',
            lineItems: const [
              RestaurantSalesLineItem(
                name: 'Meal',
                quantity: 1,
                unitPrice: 100,
                supplyAmount: 100,
                vatRate: 8,
                vatAmount: 8,
              ),
            ],
            issues: const [],
          ),
        ],
      );
      await tester.runAsync(() async {
        await (FontLoader('LedgerPreview')
              ..addFont(rootBundle.load('assets/fonts/NotoSansKR-Regular.ttf')))
            .load();
        await (FontLoader(
          'MaterialIcons',
        )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
      });
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: app(
            Scaffold(
              body: PosReceiptLedger(
                export: export,
                red: true,
                service: service,
                lookupService: CompanyTaxLookupService(
                  transport: (_, _) async => {'outcome': 'unavailable'},
                  sessionScope: () => 'fixture-session',
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(reads, 1);
      await tester.tap(find.byKey(const Key('pos_ledger_order')));
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(find.byKey(const Key('pos_legacy_number_error')), findsOneWidget);
      expect(find.textContaining('cc@example.invalid'), findsOneWidget);
      expect(find.textContaining('payment-1'), findsOneWidget);
      await tester.runAsync(() async {
        final rendered =
            await (boundary.currentContext!.findRenderObject()
                    as RenderRepaintBoundary)
                .toImage(pixelRatio: 1);
        final bytes = await rendered.toByteData(format: ui.ImageByteFormat.png);
        await File(
          '/tmp/globos-pos-ledger-preview.png',
        ).writeAsBytes(bytes!.buffer.asUint8List());
        rendered.dispose();
      });
      await tester.ensureVisible(
        find.byKey(const Key('pos_ledger_edit_buyer')),
      );
      await tester.tap(find.byKey(const Key('pos_ledger_edit_buyer')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('pos_buyer_number_value')),
        '0012345678-001',
      );
      await tester.tap(find.byKey(const Key('pos_buyer_save')));
      await tester.pumpAndSettle();
      expect(writes, 1);
      expect(reads, 1);
      expect(find.byKey(const Key('pos_legacy_number_error')), findsNothing);
      final cached = await service.page(
        day: '2026-09-04',
        entity: 'entity',
        red: true,
        orderIds: ['order'],
      );
      expect((cached.single['buyer'] as Map)['buyer_version'], 4);
      expect(reads, 1);
    },
  );
}
