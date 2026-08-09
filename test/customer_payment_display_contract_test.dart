import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/role_routes.dart';
import 'package:globos_pos_system/features/customer_display/customer_display_provider.dart';
import 'package:globos_pos_system/features/customer_display/customer_display_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';

void main() {
  test('customer display role is isolated to its dedicated route', () {
    expect(homeRouteForRole('customer_display'), '/customer-display');
    expect(
      canAccessRouteForRole('customer_display', '/customer-display'),
      isTrue,
    );
    for (final forbidden in [
      '/cashier',
      '/admin',
      '/waiter',
      '/kitchen',
      '/print-station',
      '/payments/payment-id',
    ]) {
      expect(
        canAccessRouteForRole('customer_display', forbidden),
        isFalse,
        reason: forbidden,
      );
    }
  });

  test('customer display snapshot parses fixed payment payload', () {
    final snapshot = CustomerDisplaySnapshot.fromJson({
      'order_id': 'order-1',
      'table_number': '12',
      'items': [
        {'name': 'Phở bò', 'quantity': 2, 'amount': 180000},
      ],
      'subtotal': 180000,
      'service_charge': 9000,
      'discount': 10000,
      'total': 179000,
    });

    expect(snapshot.orderId, 'order-1');
    expect(snapshot.tableNumber, '12');
    expect(snapshot.items.single.name, 'Phở bò');
    expect(snapshot.items.single.quantity, 2);
    expect(snapshot.total, 179000);
  });

  test('migration enforces dedicated read-only realtime display contract', () {
    final migration = File(
      'supabase/migrations/20260810090000_customer_payment_display.sql',
    ).readAsStringSync();

    expect(migration, contains("'device_customer_display'"));
    expect(migration, contains("'customer_display'"));
    expect(migration, contains('customer_payment_displays_select_own_store'));
    expect(migration, contains('show_customer_payment_display'));
    expect(migration, contains('clear_terminal_customer_payment_display'));
    expect(migration, contains('ADD TABLE public.customer_payment_displays'));
    expect(migration, contains("'bt_customer', 'device_customer_display'"));
    expect(migration, contains('-- production-gate: self-verifying'));
    expect(migration, contains('CUSTOMER_DISPLAY_ACCOUNT_VERIFICATION_FAILED'));
    expect(
      migration,
      isNot(contains('GRANT INSERT ON TABLE public.customer_payment_displays')),
    );
    expect(
      migration,
      isNot(contains('GRANT UPDATE ON TABLE public.customer_payment_displays')),
    );
  });

  test('customer display UI uses the existing fixed bank QR asset', () {
    final screen = File(
      'lib/features/customer_display/customer_display_screen.dart',
    ).readAsStringSync();
    expect(screen, contains('assets/images/woori_bank_account_qr.jpg'));
    expect(screen, contains("Key('customer_display_fixed_qr')"));
    expect(screen, contains("Key('customer_display_total')"));
    expect(
      File('assets/images/woori_bank_account_qr.jpg').existsSync(),
      isTrue,
    );

    final cashier = File(
      'lib/features/cashier/cashier_screen.dart',
    ).readAsStringSync();
    final paymentProvider = File(
      'lib/features/payment/payment_provider.dart',
    ).readAsStringSync();
    expect(cashier, contains("Key('cashier_show_customer_display')"));
    expect(paymentProvider, contains('show_customer_payment_display'));
  });

  testWidgets('tablet payment view renders items, total and fixed QR', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final snapshot = CustomerDisplaySnapshot.fromJson({
      'order_id': 'order-1',
      'table_number': '12',
      'items': [
        {'name': 'Phở bò', 'quantity': 2, 'amount': 180000},
        {'name': 'Khăn ướt', 'quantity': 1, 'amount': 2000},
      ],
      'subtotal': 182000,
      'service_charge': 9000,
      'discount': 10000,
      'total': 181000,
    });

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('vi'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: CustomerPaymentContent(snapshot: snapshot)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Phở bò'), findsOneWidget);
    expect(find.text('₫181.000'), findsOneWidget);
    expect(find.byKey(const Key('customer_display_fixed_qr')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
