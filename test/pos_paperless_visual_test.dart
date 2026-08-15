import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/models/fulfillment_mode.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/cashier/payment_completion_dialog.dart';
import 'package:globos_pos_system/features/customer_display/customer_display_provider.dart';
import 'package:globos_pos_system/features/customer_display/customer_display_screen.dart';
import 'package:globos_pos_system/features/digital_receipt/digital_receipt_model.dart';
import 'package:globos_pos_system/features/digital_receipt/digital_receipt_screen.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_control_panel.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_screen.dart';
import 'package:globos_pos_system/features/order/order_model.dart';
import 'package:globos_pos_system/features/payment/payment_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _captureRoot =
    '../.design/2026-08-pos-print-paperless-receipts/screenshots';
const _linuxGoldenRoot =
    '../.design/2026-08-pos-print-paperless-receipts/goldens/linux';

String get _goldenRoot => Platform.isLinux ? _linuxGoldenRoot : _captureRoot;

class _VisualEmergencyNotifier extends EmergencyFulfillmentNotifier {
  _VisualEmergencyNotifier(EmergencyFulfillmentState value) {
    state = value;
  }

  @override
  Future<void> load({bool showLoading = true}) async {}
}

class _VisualControlNotifier extends EmergencyControlNotifier {
  _VisualControlNotifier() {
    state = const EmergencyControlState(
      stores: [
        EmergencyStoreStatus(
          restaurantId: 'store-bt',
          restaurantName: 'BunsikClub Binh Thanh',
          mode: FulfillmentMode.paperless,
          unresolvedQuantity: 8,
          orderCount: 3,
          draining: false,
          kdsReady: true,
          reason: '점심 피크 페이퍼리스 운영',
        ),
        EmergencyStoreStatus(
          restaurantId: 'store-q7',
          restaurantName: 'BunsikClub District 7',
          mode: FulfillmentMode.posPrint,
          unresolvedQuantity: 0,
          orderCount: 0,
          kdsReady: true,
        ),
      ],
    );
  }

  @override
  Future<void> load() async {}
}

class _VisualAuthNotifier extends AuthNotifier {
  _VisualAuthNotifier() : super() {
    state = const PosAuthState(
      role: 'emergency_station',
      storeId: 'store-bt',
      primaryStoreId: 'store-bt',
      accessibleStores: [
        AccessibleStore(id: 'store-bt', name: 'BunsikClub Binh Thanh'),
      ],
    );
  }

  @override
  Future<void> logout() async {}
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    final fontLoader = FontLoader('Pretendard')
      ..addFont(rootBundle.load('assets/fonts/PretendardVariable.ttf'));
    await fontLoader.load();
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'test-anon-key',
      authOptions: const FlutterAuthClientOptions(detectSessionInUri: false),
    );
  });

  for (final station in ['kitchen', 'tray', 'floor']) {
    testWidgets('$station tablet paperless board capture', (tester) async {
      await _pumpKds(tester, station: station, size: const Size(1024, 768));
      await expectLater(
        find.byKey(const Key('emergency_fulfillment_screen')),
        matchesGoldenFile('$_goldenRoot/${station}_tablet_8_slots.png'),
      );
      await tester.tap(find.byKey(const Key('emergency_order_order-0')));
      await tester.pumpAndSettle();
      await expectLater(
        find.byKey(const Key('emergency_fulfillment_screen')),
        matchesGoldenFile('$_goldenRoot/${station}_tablet_menu_detail.png'),
      );
    });
  }

  testWidgets('admin operation mode and confirmation captures', (tester) async {
    _setSize(tester, const Size(1024, 768));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          emergencyControlProvider.overrideWith(
            (_) => _VisualControlNotifier(),
          ),
        ],
        child: _localizedApp(
          const Scaffold(
            body: Padding(
              padding: EdgeInsets.all(24),
              child: EmergencyControlPanel(),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byType(Scaffold),
      matchesGoldenFile('$_goldenRoot/operation_mode_admin.png'),
    );

    await tester.tap(find.byKey(const Key('emergency_toggle_store-q7')));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    await expectLater(
      find.byType(AlertDialog),
      matchesGoldenFile('$_goldenRoot/operation_mode_confirm.png'),
    );
  });

  testWidgets('paperless phone four-slot capture', (tester) async {
    await _pumpKds(tester, station: 'tray', size: const Size(390, 844));
    await expectLater(
      find.byKey(const Key('emergency_fulfillment_screen')),
      matchesGoldenFile('$_goldenRoot/tray_phone_4_slots.png'),
    );
  });

  testWidgets('cashier paperless completion capture', (tester) async {
    _setSize(tester, const Size(1024, 768));
    await tester.pumpWidget(
      _localizedApp(
        Scaffold(
          body: PaymentCompletionDialog(
            order: _cashierOrder(),
            paymentMethod: 'cash',
            receiptAccess: _receiptAccess,
            onPaperReceipt: () async {},
            onShowCustomerReceipt: () async => true,
            onReprint: () async {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const Key('cashier_payment_completion_dialog')),
      matchesGoldenFile('$_goldenRoot/cashier_paperless_completion.png'),
    );
  });

  testWidgets('customer display receipt capture', (tester) async {
    _setSize(tester, const Size(1024, 768));
    final snapshot = CustomerDisplaySnapshot.fromJson({
      'phase': 'receipt',
      'display_revision': 'revision-1',
      'receipt_id': 'receipt-1',
      'order_id': 'order-1',
      'table_number': '12',
      'total': 99000,
    }).copyWith(receiptUrl: _receiptAccess.publicUrl);
    await tester.pumpWidget(
      _localizedApp(Scaffold(body: CustomerReceiptContent(snapshot: snapshot))),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const Key('customer_display_receipt_qr')),
      matchesGoldenFile('$_goldenRoot/customer_display_receipt_qr.png'),
    );
  });

  testWidgets('public mobile receipt capture', (tester) async {
    _setSize(tester, const Size(390, 844));
    await tester.pumpWidget(
      _localizedApp(
        DigitalReceiptScreen(
          token: 'token',
          loader: (_) async => _digitalReceipt(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await expectLater(
      find.byKey(const Key('digital_receipt_root')),
      matchesGoldenFile('$_goldenRoot/public_receipt_phone.png'),
    );
  });
}

Future<void> _pumpKds(
  WidgetTester tester, {
  required String station,
  required Size size,
}) async {
  _setSize(tester, size);
  final router = GoRouter(
    initialLocation: '/emergency',
    routes: [
      GoRoute(
        path: '/emergency',
        builder: (_, _) =>
            EmergencyFulfillmentScreen(expectedStationType: station),
      ),
      GoRoute(
        path: '/change-password',
        builder: (_, _) => const SizedBox.shrink(),
      ),
    ],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((_) => _VisualAuthNotifier()),
        connectivityProvider.overrideWith((_) => Stream.value(true)),
        emergencyFulfillmentProvider.overrideWith(
          (_) => _VisualEmergencyNotifier(_kdsState(station)),
        ),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(),
        locale: const Locale('ko'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 250));
}

void _setSize(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);
}

Widget _localizedApp(Widget home) => MaterialApp(
  debugShowCheckedModeBanner: false,
  theme: AppTheme.build(),
  locale: const Locale('ko'),
  supportedLocales: AppLocalizations.supportedLocales,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  home: home,
);

EmergencyFulfillmentState _kdsState(String station) {
  final now = DateTime.now();
  return EmergencyFulfillmentState(
    assigned: true,
    active: true,
    restaurantId: 'store-bt',
    sessionId: 'session-1',
    stationType: station,
    floorLabel: station == 'floor' ? '2F' : null,
    fulfillmentMode: FulfillmentMode.paperless,
    orders: List.generate(
      5,
      (index) => EmergencyFulfillmentOrder(
        queueId: 'queue-$index',
        orderId: 'order-$index',
        queueNo: 101 + index,
        tableNumber: 'T${12 + index}',
        floorLabel: index.isEven ? '1F' : '2F',
        createdAt: now.subtract(Duration(minutes: 5 + (index * 2))),
        stationStartedAt: station == 'kitchen'
            ? now.subtract(Duration(minutes: 5 + (index * 2)))
            : now.subtract(Duration(minutes: 3 + index)),
        lastActionId: index == 0 ? 'action-previous' : null,
        lastActionAt: index == 0
            ? now.subtract(const Duration(minutes: 2))
            : null,
        items: [
          EmergencyFulfillmentItem(
            id: 'item-$index-a',
            orderItemId: 'order-item-$index-a',
            nameKo: index.isEven ? '즉석 떡볶이' : '불고기 김밥',
            nameVi: index.isEven ? 'Tokbokki' : 'Kimbap bò',
            nameEn: index.isEven ? 'Tteokbokki' : 'Bulgogi kimbap',
            orderedQuantity: 2,
            kitchenDoneQuantity: station == 'kitchen' ? 0 : 2,
            trayReceivedQuantity: station == 'floor' ? 2 : 0,
            trayDispatchedQuantity: station == 'floor' ? 1 : 0,
            floorServedQuantity: 0,
            needsReview: false,
          ),
          EmergencyFulfillmentItem(
            id: 'item-$index-b',
            orderItemId: 'order-item-$index-b',
            nameKo: '치즈 라면',
            nameVi: 'Mì phô mai',
            nameEn: 'Cheese ramen',
            orderedQuantity: 1,
            kitchenDoneQuantity: station == 'kitchen' ? 0 : 1,
            trayReceivedQuantity: station == 'floor' ? 1 : 0,
            trayDispatchedQuantity: station == 'floor' ? 1 : 0,
            floorServedQuantity: 0,
            needsReview: false,
          ),
          if (index == 0)
            const EmergencyFulfillmentItem(
              id: 'item-0-drink',
              orderItemId: 'order-item-0-drink',
              nameKo: '콜라',
              nameVi: 'Coca-Cola',
              nameEn: 'Cola',
              orderedQuantity: 2,
              kitchenDoneQuantity: 0,
              trayReceivedQuantity: 0,
              trayDispatchedQuantity: 0,
              floorServedQuantity: 0,
              needsReview: false,
              fulfillmentRoute: 'floor_direct',
            ),
        ],
      ),
    ),
  );
}

const _receiptAccess = DigitalReceiptAccess(
  receiptId: 'receipt-1',
  receiptNumber: 'BC-20260811-000001',
  token: 'token',
  publicUrl: 'https://pos.globos.world/receipt#token=demo-token',
);

CashierOrder _cashierOrder() => CashierOrder(
  orderId: 'order-1',
  tableNumber: '12',
  tableId: 'table-12',
  status: 'completed',
  orderPurpose: 'customer',
  orderSource: 'staff',
  fulfillmentMode: FulfillmentMode.paperless,
  items: const [
    OrderItem(
      id: 'item-1',
      menuItemId: 'menu-1',
      label: '즉석 떡볶이',
      unitPrice: 79000,
      quantity: 1,
      status: 'served',
      itemType: 'menu_item',
    ),
    OrderItem(
      id: 'item-2',
      menuItemId: 'menu-2',
      label: '불고기 김밥',
      unitPrice: 20000,
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
  createdAt: DateTime(2026, 8, 11, 12),
);

DigitalReceipt _digitalReceipt() => DigitalReceipt(
  id: 'receipt-1',
  orderId: 'order-1',
  receiptNumber: 'BC-20260811-000001',
  restaurantName: 'BUNSIK CLUB',
  legalName: 'CÔNG TY TNHH AKJ INTERNATIONAL',
  taxCode: '0318453298',
  addressLines: const [
    '69/1A2 Nguyễn Gia Trí',
    'Phường Thạnh Mỹ Tây, Thành phố Hồ Chí Minh',
  ],
  tableNumber: '12',
  cashierCode: 'bt_pos1',
  paidAt: DateTime(2026, 8, 11, 12, 30),
  items: const [
    DigitalReceiptItem(
      label: '즉석 떡볶이',
      quantity: 1,
      unitPrice: 79000,
      lineTotal: 79000,
      isServiceItem: false,
    ),
    DigitalReceiptItem(
      label: '불고기 김밥',
      quantity: 1,
      unitPrice: 20000,
      lineTotal: 20000,
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
