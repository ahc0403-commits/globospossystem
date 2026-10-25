import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/receipt_ledger/receipt_ledger_model.dart';
import 'package:globos_pos_system/features/receipt_ledger/receipt_ledger_screen.dart';
import 'package:globos_pos_system/features/red_invoice_intake/late_invoice_dialog.dart';
import 'package:globos_pos_system/features/red_invoice_intake/late_invoice_service.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'fixtures/sales_invoice_fixture.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/pos_receipt_ledger.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/pos_receipt_ledger_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/core/services/company_tax_lookup_service.dart';

CompanyTaxLookupService lookup() => CompanyTaxLookupService(
  transport: (_, _) async => {'outcome': 'unavailable'},
  sessionScope: () => 'fixture',
);

const target = LateInvoiceTarget(
  storeId: 'fixture-store',
  orderId: 'fixture-order',
  receiptNumber: 'BC-20261024-000123',
);
Map<String, dynamic> initial({String state = 'none', bool canEdit = true}) => {
  'state': state,
  'can_edit': canEdit,
  'order_ids': ['fixture-order'],
  'versions': {'fixture-order': null},
  'store_name': '전가복 테스트 매장',
  'gross_amount': 324000,
  'buyer': <String, dynamic>{},
};
Map<String, dynamic> completeBuyer({String phone = ''}) => {
  'buyer_number_type': 'vn_tax',
  'buyer_number_value': '0312345678',
  'buyer_legal_name': 'Công ty ABC',
  'buyer_address': '123 Nguyễn Huệ, TP. Hồ Chí Minh',
  'buyer_email': 'ketoan@example.com',
  'buyer_phone': phone,
};
Widget app(Widget child, {String locale = 'ko'}) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.build(),
  locale: Locale(locale),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: const [
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  home: Scaffold(backgroundColor: const Color(0xFFF5F7FA), body: child),
);
Future<void> fill(WidgetTester tester, {String phone = ''}) async {
  for (final e in completeBuyer(
    phone: phone,
  ).entries.where((e) => e.key != 'buyer_number_type')) {
    await tester.ensureVisible(find.byKey(Key('pos_${e.key}')));
    await tester.enterText(find.byKey(Key('pos_${e.key}')), e.value as String);
  }
  await tester.ensureVisible(find.byKey(const Key('late_invoice_submit')));
  await tester.pumpAndSettle();
}

Future<void> capture(
  WidgetTester tester,
  GlobalKey boundary,
  String name,
) async {
  final path = Platform.environment['LATE_INVOICE_SCREENSHOT_DIR'];
  if (path == null) return;
  await tester.runAsync(() async {
    await Directory(path).create(recursive: true);
    final rendered =
        await (boundary.currentContext!.findRenderObject()
                as RenderRepaintBoundary)
            .toImage(pixelRatio: 1.5);
    final png = await rendered.toByteData(format: ui.ImageByteFormat.png);
    await File('$path/$name.png').writeAsBytes(png!.buffer.asUint8List());
    rendered.dispose();
  });
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await (FontLoader(
      'Pretendard',
    )..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf'))).load();
    await (FontLoader(
      'MaterialIcons',
    )..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'))).load();
  });
  testWidgets(
    'cashier receipt opens common form and saves once without phone',
    (tester) async {
      tester.view.physicalSize = const Size(1024, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final gate = Completer<void>();
      final writes = <Map<String, dynamic>>[];
      final service = LateInvoiceService(
        sessionScope: () => 'fixture',
        rpc: (name, params) async {
          if (name == 'pos_late_invoice_context') return initial();
          writes.add(params);
          await gate.future;
          return {
            ...initial(state: 'ready'),
            'versions': {'fixture-order': 1},
            'buyer': {
              ...completeBuyer(),
              'id': 'fixture-intake',
              'buyer_version': 1,
            },
          };
        },
      );
      final boundary = GlobalKey();
      await tester.pumpWidget(
        RepaintBoundary(
          key: boundary,
          child: app(
            ReceiptLedgerDetailDialog(
              entry: ReceiptLedgerEntry.fromJson({
                'receipt_id': 'fixture-receipt',
                'receipt_number': target.receiptNumber,
                'order_id': target.orderId,
                'order_ids': [target.orderId],
                'store_id': target.storeId,
                'store_name': '전가복 테스트 매장',
                'sold_at': DateTime(2026, 10, 24, 12, 45, 42).toIso8601String(),
                'table_number': '1212',
                'sales_channel': 'dine_in',
                'cashier_name': 'TEST CASHIER',
                'payments': [
                  {'method': 'BANKTRANSFER', 'amount': 324000},
                ],
                'items': [
                  {
                    'name': '해물짬뽕',
                    'name_ko': '해물짬뽕',
                    'quantity': 2,
                    'unit_price': 100000,
                  },
                  {
                    'name': '탕수육 S',
                    'name_ko': '탕수육 S',
                    'quantity': 1,
                    'unit_price': 100000,
                  },
                ],
                'gross_amount': 324000,
                'net_amount': 324000,
                'received_amount': 324000,
                'receipt_status': 'paid',
                'receipt_source': 'pos',
                'printable': true,
                'invoice_state': 'none',
              }),
              invoiceService: service,
              lookupService: lookup(),
              onReprint: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('레드인보이스 추가 발행'), findsOneWidget);
      await capture(tester, boundary, '01-receipt-detail');
      await tester.tap(find.byKey(const Key('receipt_ledger_late_invoice')));
      await tester.pumpAndSettle();
      await fill(tester);
      expect(find.textContaining('선택'), findsWidgets);
      await capture(tester, boundary, '02-buyer-form');
      await tester.tap(find.byKey(const Key('late_invoice_submit')));
      await tester.pump();
      await tester.tap(find.byKey(const Key('late_invoice_submit')));
      await tester.pump();
      expect(writes, hasLength(1));
      expect(tester.testTextInput.hasAnyClients, isFalse);
      expect((writes.single['p_patch'] as Map)['buyer_phone'], '');
      gate.complete();
      await tester.pumpAndSettle();
      expect(find.text('레드인보이스 요청이 접수되었습니다'), findsOneWidget);
      expect(find.text('발행 대기'), findsOneWidget);
      await capture(tester, boundary, '03-request-received');
      await tester.tap(find.text('영수증으로 돌아가기'));
      await tester.pumpAndSettle();
      expect(find.text('발행 대기'), findsOneWidget);
      expect(find.text('발행 상태 보기'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets(
    'uncertain response retries the same request identity and retains input',
    (tester) async {
      final writes = <Map<String, dynamic>>[];
      final service = LateInvoiceService(
        sessionScope: () => 'fixture',
        rpc: (name, p) async {
          if (name == 'pos_late_invoice_context') return initial();
          writes.add(p);
          if (writes.length == 1) {
            throw const PostgrestException(message: 'network result unknown');
          }
          return {...initial(state: 'ready'), 'buyer': completeBuyer()};
        },
      );
      await tester.pumpWidget(
        app(
          LateInvoiceDialog(
            target: target,
            service: service,
            lookupService: lookup(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await fill(tester, phone: '02800000000');
      await tester.tap(find.byKey(const Key('late_invoice_submit')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('late_invoice_error')), findsOneWidget);
      expect(find.text('02800000000'), findsOneWidget);
      await tester.tap(find.byKey(const Key('late_invoice_submit')));
      await tester.pumpAndSettle();
      expect(writes, hasLength(2));
      expect(writes.first['p_request_id'], writes.last['p_request_id']);
      expect((writes.last['p_patch'] as Map)['buyer_phone'], '02800000000');
    },
  );
  testWidgets('issued state never offers another request', (tester) async {
    var writes = 0;
    final service = LateInvoiceService(
      sessionScope: () => 'fixture',
      rpc: (name, p) async {
        if (name != 'pos_late_invoice_context') writes++;
        return initial(state: 'issued', canEdit: false);
      },
    );
    await tester.pumpWidget(
      app(
        LateInvoiceDialog(
          target: target,
          service: service,
          lookupService: lookup(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('late_invoice_submit')), findsNothing);
    expect(find.text('MISA에서 확인'), findsOneWidget);
    expect(writes, 0);
  });
  for (final locale in ['ko', 'vi', 'en']) {
    testWidgets(
      'narrow $locale form supports optional phone and incomplete draft',
      (tester) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final writes = <Map<String, dynamic>>[];
        final service = LateInvoiceService(
          sessionScope: () => 'fixture',
          rpc: (name, p) async {
            if (name == 'pos_late_invoice_context') return initial();
            writes.add(p);
            return initial(state: 'draft');
          },
        );
        await tester.pumpWidget(
          app(
            LateInvoiceDialog(
              target: target,
              service: service,
              lookupService: lookup(),
            ),
            locale: locale,
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.byKey(const Key('late_invoice_draft')));
        await tester.pumpAndSettle();
        expect(writes.single['p_confirm'], false);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'administrator creates buyer from general ledger and updates classification',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final payload =
          jsonDecode(
                File(
                  'test/fixtures/corporate_sales_reference.json',
                ).readAsStringSync(),
              )
              as Map<String, dynamic>;
      final raw = (payload['receipts'] as List).single as Map<String, dynamic>;
      raw['is_red_invoice'] = false;
      final export = createRestaurantSalesExport(
        approvedSalesFixturePayload(payload),
      );
      final receipt = export.receipts.single;
      var changed = 0;
      Map<String, dynamic>? write;
      final ledger = PosReceiptLedgerService(
        sessionScope: () => 'fixture',
        rpc: (name, p) async => {
          'rows': [
            {'order_id': receipt.receiptId, 'payments': [], 'buyer': {}},
          ],
        },
      );
      final late = LateInvoiceService(
        sessionScope: () => 'fixture',
        rpc: (name, p) async {
          if (name == 'pos_late_invoice_context') return initial();
          write = p;
          return {
            ...initial(state: 'ready'),
            'buyer': {...completeBuyer(), 'buyer_version': 1},
          };
        },
      );
      await tester.pumpWidget(
        app(
          PosReceiptLedger(
            export: export,
            red: false,
            service: ledger,
            lookupService: lookup(),
            lateInvoiceService: late,
            onChanged: () => changed++,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(Key('pos_ledger_${receipt.receiptId}')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('pos_ledger_late_invoice')),
      );
      await tester.tap(find.byKey(const Key('pos_ledger_late_invoice')));
      await tester.pumpAndSettle();
      await fill(tester);
      await tester.tap(find.byKey(const Key('late_invoice_submit')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('영수증으로 돌아가기'));
      await tester.pumpAndSettle();
      expect(write?['p_order_id'], receipt.receiptId);
      expect(changed, 1);
      expect(tester.takeException(), isNull);
    },
  );
  test('service binds the original login across load and submit', () async {
    var session = 'one';
    var calls = 0;
    final service = LateInvoiceService(
      sessionScope: () => session,
      rpc: (name, params) async {
        calls++;
        return initial();
      },
    );
    await service.load(target);
    session = 'two';
    await expectLater(
      service.submit(
        target: target,
        requestId: 'fixture-request',
        versions: {'fixture-order': null},
        patch: completeBuyer(),
        confirm: true,
      ),
      throwsStateError,
    );
    expect(calls, 1);
  });
  test('service rejects completion after login changes', () async {
    var session = 'one';
    final gate = Completer<void>();
    final service = LateInvoiceService(
      sessionScope: () => session,
      rpc: (n, p) async {
        await gate.future;
        return initial();
      },
    );
    final load = service.load(target);
    session = 'two';
    gate.complete();
    await expectLater(load, throwsStateError);
  });
  test(
    'registered buyer workbook allows blank phone and preserves leading zero',
    () {
      for (final phone in ['', '02800000000']) {
        final payload =
            jsonDecode(
                  File(
                    'test/fixtures/corporate_sales_reference.json',
                  ).readAsStringSync(),
                )
                as Map<String, dynamic>;
        final row =
            (payload['receipts'] as List).single as Map<String, dynamic>;
        row.addAll({
          'is_red_invoice': true,
          'red_invoice_status': 'ready',
          'buyer_tax_code': '0312345678',
          'buyer_legal_name': 'Fixture Company',
          'buyer_address': 'Fixture address',
          'buyer_email': 'buyer@example.invalid',
          'buyer_phone': phone,
        });
        final export = createRestaurantSalesExport(
          approvedSalesFixturePayload(payload),
        );
        expect(export.isReadyForDownload, isTrue);
        final book = Excel.decodeBytes(buildRestaurantSalesWorkbook(export));
        expect(
          book.tables['Hóa đơn GTGT']!.rows[8][7]?.value.toString() ?? '',
          phone,
        );
      }
    },
  );
}
