import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/models/fulfillment_mode.dart';
import 'package:globos_pos_system/core/services/digital_receipt_service.dart';
import 'package:globos_pos_system/features/cashier/payment_completion_dialog.dart';
import 'package:globos_pos_system/features/customer_display/customer_display_provider.dart';
import 'package:globos_pos_system/features/customer_display/customer_display_screen.dart';
import 'package:globos_pos_system/features/digital_receipt/digital_receipt_model.dart';
import 'package:globos_pos_system/features/digital_receipt/digital_receipt_screen.dart';
import 'package:globos_pos_system/features/order/order_model.dart';
import 'package:globos_pos_system/features/payment/payment_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

void main() {
  test(
    'mode routing and immutable receipt migration preserves hard contracts',
    () {
      final migration = File(
        'supabase/migrations/20260811170000_pos_paperless_receipts.sql',
      ).readAsStringSync();
      final pgcryptoFix = File(
        'supabase/migrations/'
        '20260811180000_fix_public_receipt_pgcrypto_schema.sql',
      ).readAsStringSync();

      expect(migration, contains("DEFAULT 'pos_print'"));
      expect(migration, contains('orders.fulfillment_mode_snapshot'));
      expect(migration, contains('order_items.fulfillment_mode_snapshot'));
      expect(migration, contains('capture_order_fulfillment_mode_trigger'));
      expect(
        migration,
        contains('capture_order_item_fulfillment_mode_trigger'),
      );
      expect(migration, contains("NEW.copy_type = 'receipt'"));
      expect(migration, contains('PAPERLESS_DIGITAL_ROUTING'));
      expect(migration, contains('close_drained_paperless_session_trigger'));
      expect(migration, contains('UNIQUE (order_id)'));
      expect(migration, contains("digest(v_token, 'sha256')"));
      expect(migration, contains("digest(p_token, 'sha256')"));
      expect(migration, contains('gen_random_bytes(24)'));
      expect(migration, contains("interval '90 days'"));
      expect(migration, contains('OFFSET 2'));
      expect(migration, contains('consume_digital_receipt_rate_limit'));
      expect(
        migration,
        contains("last_presented_at < now() - interval '1 day'"),
      );
      expect(migration, contains('REVOKE ALL ON public.digital_receipts'));
      expect(
        migration,
        contains('GRANT EXECUTE ON FUNCTION public.get_public_receipt'),
      );
      expect(migration, isNot(contains('red_invoice_intakes')));
      expect(migration, isNot(contains('einvoice_jobs')));
      expect(pgcryptoFix, contains('extensions.gen_random_bytes(24)'));
      expect(pgcryptoFix, contains("extensions.digest(v_token, 'sha256')"));
      expect(pgcryptoFix, contains("extensions.digest(p_token, 'sha256')"));
      expect(pgcryptoFix, contains("pg_notify('pgrst', 'reload schema')"));
    },
  );

  test('cashier keeps payment commit separate from receipt presentation', () {
    final cashier = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();
    final provider = File(
      'lib/features/payment/payment_provider.dart',
    ).readAsStringSync();

    expect(
      cashier,
      contains('if (!selectedOrder.fulfillmentMode.isPaperless)'),
    );
    expect(cashier, contains('_prepareDigitalReceipt'));
    expect(cashier, contains('receiptAccess: receiptAccess'));
    expect(cashier, contains('RedInvoiceModal'));
    expect(provider, contains("'show_customer_receipt_display'"));
    expect(provider, contains("'phase': 'payment'"));
    expect(provider, isNot(contains('ensure_digital_receipt')));
  });

  test(
    'public receipt route bypasses login without weakening other guards',
    () {
      final router = File('lib/core/router/app_router.dart').readAsStringSync();
      expect(router, contains("if (path == '/receipt')"));
      expect(router, contains("path: '/receipt'"));
      expect(router, contains('DigitalReceiptScreen('));
      expect(router, contains("push('/receipt')"));
      expect(router, isNot(contains("path: '/receipt/:token'")));
      expect(router, contains("path.startsWith('/qr/')"));
    },
  );

  test(
    'public receipt token stays out of server-visible URLs and direct RPC',
    () {
      const token = 'abcdefghijklmnopqrstuvwxyzABCDEF';
      final service = File(
        'lib/core/services/digital_receipt_service.dart',
      ).readAsStringSync();
      final index = File('web/index.html').readAsStringSync();
      final vercel = File('vercel.json').readAsStringSync();
      final edge = File(
        'supabase/functions/public-receipt/index.ts',
      ).readAsStringSync();

      expect(
        DigitalReceiptService.publicUrlForToken(token),
        'https://globospossystem.vercel.app/receipt#token=$token',
      );
      expect(service, contains("functions.invoke(\n      'public-receipt'"));
      expect(
        service,
        isNot(contains("supabase.rpc(\n      'get_public_receipt'")),
      );
      expect(index, contains('window.history.replaceState'));
      expect(index, contains('globosTakeDigitalReceiptToken'));
      expect(index, isNot(contains('sessionStorage')));
      expect(vercel, contains('no-store, max-age=0, must-revalidate'));
      expect(vercel, contains('noindex, nofollow, noarchive'));
      expect(edge, contains('consume_digital_receipt_rate_limit'));
      expect(edge, contains('DIGITAL_RECEIPT_RATE_LIMIT_SECRET'));
      expect(edge, contains('SUPABASE_SECRET_KEYS'));
      expect(edge, contains('PUBLIC_RECEIPT_SUPABASE_SECRET_KEY_NAME'));
      expect(edge, isNot(contains('SUPABASE_SERVICE_ROLE_KEY')));
      expect(edge, isNot(contains('console.log')));
    },
  );

  testWidgets('paperless completion shows QR and explicit paper choice', (
    tester,
  ) async {
    var paperPrints = 0;
    final order = _fixtureOrder(FulfillmentMode.paperless);
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: PaymentCompletionDialog(
            order: order,
            paymentMethod: 'cash',
            receiptAccess: const DigitalReceiptAccess(
              receiptId: 'receipt-1',
              receiptNumber: 'BC-1',
              token: 'token',
              publicUrl: 'https://pos.globos.world/receipt#token=token',
            ),
            onPaperReceipt: () async => paperPrints += 1,
            onReprint: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('cashier_digital_receipt_panel')), findsOne);
    expect(
      find.byKey(const Key('cashier_payment_completion_paper_receipt')),
      findsOne,
    );
    expect(
      find.byKey(const Key('cashier_payment_completion_reprint')),
      findsNothing,
    );
    await tester.tap(
      find.byKey(const Key('cashier_payment_completion_paper_receipt')),
    );
    await tester.pump();
    expect(paperPrints, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('customer receipt phase uses a dynamic receipt QR', (
    tester,
  ) async {
    final snapshot = CustomerDisplaySnapshot.fromJson({
      'phase': 'receipt',
      'display_revision': 'revision-1',
      'receipt_id': 'receipt-1',
      'order_id': 'order-1',
      'table_number': '12',
      'total': 99000,
    }).copyWith(receiptUrl: 'https://pos.globos.world/receipt#token=token');

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: CustomerReceiptContent(snapshot: snapshot)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('customer_display_receipt_qr')), findsOne);
    expect(find.byKey(const Key('customer_display_fixed_qr')), findsNothing);
    expect(find.text('Thanh toán thành công'), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('public receipt renders proof notice and PDF/print actions', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ko'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: DigitalReceiptScreen(
          token: 'token',
          loader: (_) async => _fixtureReceipt(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('digital_receipt_paper')), findsOne);
    expect(find.byKey(const Key('digital_receipt_total')), findsOne);
    expect(find.textContaining('적색 세금계산서가 아닙니다'), findsOne);
    await tester.scrollUntilVisible(
      find.byKey(const Key('digital_receipt_save_pdf')),
      500,
      scrollable: find.byType(Scrollable).first,
    );
    expect(find.byKey(const Key('digital_receipt_save_pdf')), findsOne);
    expect(find.byKey(const Key('digital_receipt_browser_print')), findsOne);
    expect(tester.takeException(), isNull);
  });
}

CashierOrder _fixtureOrder(FulfillmentMode mode) => CashierOrder(
  orderId: 'order-1',
  tableNumber: '12',
  tableId: 'table-1',
  status: 'completed',
  orderPurpose: 'customer',
  orderSource: 'staff',
  fulfillmentMode: mode,
  items: const [
    OrderItem(
      id: 'item-1',
      menuItemId: 'menu-1',
      label: '떡볶이',
      unitPrice: 99000,
      quantity: 1,
      status: 'served',
      itemType: 'menu_item',
    ),
  ],
  menuSubtotal: 99000,
  serviceChargeTotal: 0,
  serviceItemTotal: 0,
  fixedChargeTotal: 0,
  discountTotal: 0,
  vatTotal: 9000,
  totalAmount: 99000,
  paidTotal: 99000,
  paymentCount: 1,
  remainingDue: 99000,
  createdAt: DateTime(2026, 8, 11),
);

DigitalReceipt _fixtureReceipt() => DigitalReceipt(
  id: 'receipt-1',
  orderId: 'order-1',
  receiptNumber: 'BC-20260811-000001',
  restaurantName: 'BUNSIK CLUB',
  addressLines: const ['69/1A2 Nguyễn Gia Trí'],
  tableNumber: '12',
  cashierCode: 'bt_pos1',
  paidAt: DateTime(2026, 8, 11, 12),
  items: const [
    DigitalReceiptItem(
      label: '떡볶이',
      quantity: 1,
      unitPrice: 99000,
      lineTotal: 99000,
      isServiceItem: false,
    ),
  ],
  payments: const [DigitalReceiptPayment(method: 'CASH', amount: 99000)],
  subtotalAmount: 99000,
  serviceChargeAmount: 0,
  discountAmount: 0,
  vatAmount: 9000,
  totalAmount: 99000,
  receivedAmount: 100000,
  changeAmount: 1000,
  paymentMethod: 'CASH',
  isService: false,
);
