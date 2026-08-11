import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/role_routes.dart';
import 'package:globos_pos_system/features/customer_display/customer_display_provider.dart';
import 'package:globos_pos_system/features/customer_display/customer_display_screen.dart';
import 'package:globos_pos_system/features/order/order_model.dart';
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
      'locale_code': 'vi',
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
    expect(snapshot.localeCode, 'vi');
    expect(snapshot.tableNumber, '12');
    expect(snapshot.items.single.name, 'Phở bò');
    expect(snapshot.items.single.quantity, 2);
    expect(snapshot.total, 179000);
  });

  test('customer display realtime path uses store_id and direct records', () {
    final provider = File(
      'lib/features/customer_display/customer_display_provider.dart',
    ).readAsStringSync();

    expect(
      provider,
      contains("LiveSyncScope.storeFilter(storeId, column: 'store_id')"),
    );
    expect(provider, contains('payload.newRecord'));
    expect(provider, contains('_applyRow(storeId, row)'));
    expect(
      provider,
      isNot(contains('callback: (_) => unawaited(_load(storeId))')),
    );
    expect(
      provider.indexOf('.subscribe((status, [error])'),
      lessThan(provider.indexOf('await _load(storeId);')),
    );
  });

  test('customer display polls within one second only while disconnected', () {
    expect(
      CustomerDisplayNotifier.fallbackIntervalForConnection(connected: false),
      const Duration(seconds: 1),
    );
    expect(
      CustomerDisplayNotifier.fallbackIntervalForConnection(connected: true),
      const Duration(seconds: 15),
    );
  });

  test('order item exposes the Vietnamese name for customer display', () {
    final item = OrderItem(
      id: 'item-1',
      menuItemId: 'menu-1',
      label: 'Legacy label',
      unitPrice: 99000,
      quantity: 1,
      status: 'ready',
      itemType: 'menu_item',
      nameKo: '전통 떡볶이',
      nameVi: 'Tteokbokki truyền thống',
      nameEn: 'Traditional tteokbokki',
    );

    expect(item.localizedName('vi'), 'Tteokbokki truyền thống');
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
    expect(paymentProvider, contains("'locale_code': 'vi'"));
    expect(paymentProvider, contains("item.localizedName('vi')"));
    expect(screen, contains('Duration(milliseconds: 120)'));
  });

  testWidgets('customer display fixed copy is always Vietnamese', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    const localeCodes = ['ko', 'vi', 'en'];
    const vietnameseCopy = [
      'Chi tiết đơn hàng',
      'Tổng thanh toán',
      'Quét mã QR để thanh toán',
      'Bàn 12',
      'Phí dịch vụ',
      'Giảm giá',
    ];

    for (final localeCode in localeCodes) {
      final snapshot = CustomerDisplaySnapshot.fromJson({
        'order_id': 'order-$localeCode',
        'locale_code': localeCode,
        'table_number': '12',
        'items': [
          {'name': 'Menu item', 'quantity': 1, 'amount': 99000},
        ],
        'subtotal': 99000,
        'service_charge': 9000,
        'discount': 10000,
        'total': 99000,
      });

      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('ko'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: CustomerPaymentContent(snapshot: snapshot)),
        ),
      );
      await tester.pumpAndSettle();

      for (final expected in vietnameseCopy) {
        expect(find.text(expected), findsOneWidget, reason: localeCode);
      }
      expect(find.text('주문 내역'), findsNothing, reason: localeCode);
      expect(find.text('Order details'), findsNothing, reason: localeCode);
      expect(tester.takeException(), isNull, reason: localeCode);
    }
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
      'locale_code': 'vi',
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
        locale: const Locale('ko'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: CustomerPaymentContent(snapshot: snapshot)),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Phở bò'), findsOneWidget);
    expect(find.text('Chi tiết đơn hàng'), findsOneWidget);
    expect(find.text('Quét mã QR để thanh toán'), findsOneWidget);
    expect(find.text('주문 내역'), findsNothing);
    expect(find.text('₫181.000'), findsOneWidget);
    expect(find.byKey(const Key('customer_display_fixed_qr')), findsOneWidget);
    expect(find.byType(Image), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet payment view keeps at least eight order rows visible', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final snapshot = CustomerDisplaySnapshot.fromJson({
      'order_id': 'order-eight',
      'locale_code': 'ko',
      'table_number': '12',
      'items': [
        for (var index = 1; index <= 8; index++)
          {'name': 'Món Việt $index', 'quantity': 1, 'amount': 10000 * index},
      ],
      'subtotal': 360000,
      'service_charge': 0,
      'discount': 0,
      'total': 360000,
    });

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('ko'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: CustomerPaymentContent(snapshot: snapshot)),
      ),
    );
    await tester.pumpAndSettle();

    for (var index = 0; index < 8; index++) {
      final row = find.byKey(ValueKey('customer_display_item_$index'));
      expect(row, findsOneWidget);
      expect(tester.getBottomLeft(row).dy, lessThan(768));
    }
    expect(find.text('Chi tiết đơn hàng'), findsOneWidget);
    expect(find.text('주문 내역'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
