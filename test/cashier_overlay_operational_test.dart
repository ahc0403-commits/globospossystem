import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/payment_method_contract.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/core/services/payment_proof_service.dart';
import 'package:globos_pos_system/core/services/payment_service.dart';
import 'package:globos_pos_system/core/services/restaurant_cutoff_service.dart';
import 'package:globos_pos_system/core/models/pos_table.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/cashier/cashier_screen.dart';
import 'package:globos_pos_system/features/order/order_model.dart';
import 'package:globos_pos_system/features/payment/payment_provider.dart';
import 'package:globos_pos_system/features/table/table_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '7f6c9d22-6d84-4c7f-b923-79c81c4015d1';
const _orderId = 'cashier-order-a1';

const _authState = PosAuthState(
  role: 'store_admin',
  storeId: _storeId,
  primaryStoreId: _storeId,
  accessibleStores: [AccessibleStore(id: _storeId, name: 'GLOBOS Nguyễn Huệ')],
  extraPermissions: ['discount_apply'],
);

final _cashierOrder = CashierOrder(
  orderId: _orderId,
  tableNumber: 'A1',
  tableId: 'table-a1',
  status: 'serving',
  orderPurpose: 'customer',
  orderSource: 'staff',
  items: const [
    OrderItem(
      id: 'cashier-item-pho',
      menuItemId: 'menu-pho',
      label: 'Phở bò đặc biệt',
      unitPrice: 100000,
      quantity: 1,
      status: 'ready',
      itemType: 'menu_item',
    ),
    OrderItem(
      id: 'cashier-item-coffee',
      menuItemId: 'menu-coffee',
      label: 'Cà phê sữa đá',
      unitPrice: 40000,
      quantity: 1,
      status: 'ready',
      itemType: 'menu_item',
    ),
  ],
  menuSubtotal: 140000,
  serviceChargeTotal: 0,
  serviceItemTotal: 0,
  discountTotal: 0,
  totalAmount: 140000,
  paidTotal: 0,
  paymentCount: 0,
  remainingDue: 140000,
  createdAt: DateTime(2026, 7, 18, 12),
);

class _AuthNotifier extends AuthNotifier {
  _AuthNotifier() : super() {
    state = _authState;
  }

  @override
  Future<void> logout() async {}
}

class _PaymentNotifier extends PaymentNotifier {
  _PaymentNotifier() {
    state = PaymentState(orders: [_cashierOrder]);
  }

  int cancelledOrders = 0;
  int serviceItemMutations = 0;

  @override
  Future<void> loadOrders(String storeId) async {}

  @override
  Future<Map<String, dynamic>?> processPayment(
    String storeId,
    String orderId,
    double amount,
    String method,
  ) async {
    state = state.copyWith(paymentSuccess: true, isProcessing: false);
    return {'id': 'payment-single'};
  }

  @override
  Future<List<Map<String, dynamic>>?> processPaymentSplits(
    String storeId,
    String orderId,
    double orderTotal,
    List<PaymentSplitInput> splits,
  ) async {
    state = state.copyWith(paymentSuccess: true, isProcessing: false);
    return [
      for (var index = 0; index < splits.length; index++)
        {'id': 'payment-split-$index'},
    ];
  }

  @override
  Future<bool> markOrderItemService({
    required String storeId,
    required String itemId,
    required String reason,
    required String managerPin,
  }) async {
    serviceItemMutations += 1;
    return true;
  }

  @override
  Future<void> cancelOrder(String orderId, String storeId) async {
    cancelledOrders += 1;
  }
}

class _TableNotifier extends WaiterTableNotifier {
  _TableNotifier() {
    state = const WaiterTableState(
      tables: [
        PosTable(
          id: 'table-a1',
          storeId: _storeId,
          tableNumber: 'A1',
          seatCount: 4,
          status: 'occupied',
        ),
      ],
    );
  }

  @override
  Future<void> loadTables(String storeId, {bool showLoading = true}) async {}
}

class _PaymentProofService extends PaymentProofService {
  int markRequiredCalls = 0;

  @override
  Future<int> flushPendingUploads() async => 0;

  @override
  Future<void> markProofRequired({
    required String paymentId,
    required String storeId,
  }) async {
    markRequiredCalls += 1;
  }
}

class _PaymentService extends PaymentService {
  double? receivedAmount;

  @override
  Future<Map<String, dynamic>> enqueueReceiptPrintJob({
    required String orderId,
    double? receivedAmount,
    bool reprint = false,
  }) async {
    this.receivedAmount = receivedAmount;
    return {'status': 'done'};
  }
}

class _CutoffService extends RestaurantCutoffService {
  @override
  Future<RestaurantCutoffState> fetchState(String storeId) async =>
      const RestaurantCutoffState(
        isRestaurant: true,
        phase: 'open',
        canCreateOrder: true,
        canCompletePayment: true,
      );
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'test-anon-key',
    );
  });

  testWidgets('all non-post-payment Cashier overlays open from live controls', (
    tester,
  ) async {
    final harness = await _pumpCashier(tester);
    await _selectOrder(tester);

    await tester.tap(find.byKey(const Key('payment_submit_button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('cashier_payment_method_dialog')),
      findsOneWidget,
    );
    await tester.tap(
      find.byKey(const Key('cashier_method_dialog_$paymentMethodCash')),
    );
    await tester.pumpAndSettle();

    await _openAndDismiss(
      tester,
      action: find.byKey(const Key('cashier_selected_amount_button')),
      surface: find.byKey(const Key('cashier_order_items_sheet')),
    );
    await _openAndDismiss(
      tester,
      action: find.byKey(
        const Key('cashier_service_item_action_cashier-item-pho'),
      ),
      surface: find.byKey(const Key('cashier_service_item_dialog')),
    );
    await _openAndDismiss(
      tester,
      action: find.byKey(const Key('cashier_discount_button')),
      surface: find.byKey(const Key('cashier_discount_dialog')),
    );
    await _openAndDismiss(
      tester,
      action: find.byKey(const Key('cashier_split_payment_button')),
      surface: find.byKey(const Key('cashier_split_payment_dialog')),
    );
    await _openAndDismiss(
      tester,
      action: find.byKey(const Key('cashier_cancel_order_action')),
      surface: find.byKey(const Key('cashier_cancel_order_dialog')),
    );

    expect(harness.notifier.cancelledOrders, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('single payment executes proof and red-invoice call sites', (
    tester,
  ) async {
    final harness = await _pumpCashier(tester);
    await _selectOrder(tester);

    await tester.ensureVisible(
      find.byKey(const Key('cashier_method_tile_$paymentMethodOther')),
    );
    await tester.tap(
      find.byKey(const Key('cashier_method_tile_$paymentMethodOther')),
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('payment_submit_button')));
    await tester.tap(find.byKey(const Key('payment_submit_button')));
    await _pumpUntilFound(
      tester,
      find.byKey(const Key('cashier_single_payment_proof_dialog')),
    );
    _dismiss(tester, const Key('cashier_single_payment_proof_dialog'));
    await _pumpUntilFound(
      tester,
      find.byKey(const Key('cashier_single_red_invoice_dialog')),
    );
    _dismiss(tester, const Key('cashier_single_red_invoice_dialog'));
    await _pumpUntilFound(
      tester,
      find.byKey(const Key('cashier_payment_completion_dialog')),
    );

    expect(harness.proofService.markRequiredCalls, 1);
    expect(
      find.byKey(const Key('cashier_payment_completion_dialog')),
      findsOneWidget,
    );
    _dismiss(tester, const Key('cashier_payment_completion_dialog'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('cash payment calculates change and sends tender to receipt', (
    tester,
  ) async {
    final harness = await _pumpCashier(tester);
    await _selectOrder(tester);

    await tester.ensureVisible(
      find.byKey(const Key('cashier_method_tile_$paymentMethodCash')),
    );
    await tester.tap(
      find.byKey(const Key('cashier_method_tile_$paymentMethodCash')),
    );
    await tester.pump();
    await tester.ensureVisible(find.byKey(const Key('payment_submit_button')));
    await tester.tap(find.byKey(const Key('payment_submit_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('cashier_cash_tender_dialog')), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('cashier_cash_received_input')),
      '400000',
    );
    await tester.pump();
    expect(find.text('₫260.000'), findsWidgets);
    await tester.tap(find.byKey(const Key('cashier_cash_tender_confirm')));

    await _pumpUntilFound(
      tester,
      find.byKey(const Key('cashier_single_red_invoice_dialog')),
    );
    _dismiss(tester, const Key('cashier_single_red_invoice_dialog'));
    await _pumpUntilFound(
      tester,
      find.byKey(const Key('cashier_payment_completion_dialog')),
    );

    expect(harness.paymentService.receivedAmount, 400000);
    expect(find.text('₫260.000'), findsWidgets);
  });

  testWidgets('split payment executes proof and red-invoice call sites', (
    tester,
  ) async {
    final harness = await _pumpCashier(tester);
    await _selectOrder(tester);

    final splitAction = find.byKey(const Key('cashier_split_payment_button'));
    await tester.ensureVisible(splitAction);
    await tester.tap(splitAction);
    await tester.pumpAndSettle();
    final splitDialog = find.byKey(const Key('cashier_split_payment_dialog'));
    expect(splitDialog, findsOneWidget);
    await tester.tap(
      find.descendant(of: splitDialog, matching: find.byType(FilledButton)),
    );
    await _pumpUntilFound(
      tester,
      find.byKey(const Key('cashier_split_payment_proof_dialog')),
    );
    _dismiss(tester, const Key('cashier_split_payment_proof_dialog'));
    await _pumpUntilFound(
      tester,
      find.byKey(const Key('cashier_split_red_invoice_dialog')),
    );
    _dismiss(tester, const Key('cashier_split_red_invoice_dialog'));
    await _pumpUntilFound(
      tester,
      find.byKey(const Key('cashier_payment_completion_dialog')),
    );

    expect(harness.proofService.markRequiredCalls, 1);
    expect(
      find.byKey(const Key('cashier_payment_completion_dialog')),
      findsOneWidget,
    );
    _dismiss(tester, const Key('cashier_payment_completion_dialog'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

class _CashierHarness {
  const _CashierHarness({
    required this.notifier,
    required this.proofService,
    required this.paymentService,
  });

  final _PaymentNotifier notifier;
  final _PaymentProofService proofService;
  final _PaymentService paymentService;
}

Future<_CashierHarness> _pumpCashier(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 1000);
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final notifier = _PaymentNotifier();
  final proofService = _PaymentProofService();
  final paymentService = _PaymentService();
  final router = GoRouter(
    initialLocation: '/cashier',
    routes: [
      GoRoute(
        path: '/cashier',
        builder: (_, __) => CashierScreen(
          paymentProofServiceOverride: proofService,
          paymentServiceOverride: paymentService,
          restaurantCutoffServiceOverride: _CutoffService(),
        ),
      ),
      GoRoute(
        path: '/payments/:id',
        builder: (_, __) => const Scaffold(
          key: Key('payment-result-route'),
          body: SizedBox.shrink(),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _AuthNotifier()),
        connectivityProvider.overrideWith((ref) => Stream.value(true)),
        paymentProvider.overrideWith((ref) => notifier),
        waiterTableProvider.overrideWith((ref) => _TableNotifier()),
        restaurantCutoffStateProvider.overrideWith(
          (ref, storeId) => Stream.value(
            const RestaurantCutoffState(
              isRestaurant: true,
              phase: 'open',
              canCreateOrder: true,
              canCompletePayment: true,
            ),
          ),
        ),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(),
        locale: const Locale('vi'),
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
  await tester.pumpAndSettle();
  return _CashierHarness(
    notifier: notifier,
    proofService: proofService,
    paymentService: paymentService,
  );
}

Future<void> _selectOrder(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('cashier_order_$_orderId')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('cashier_payment_surface')), findsOneWidget);
}

Future<void> _openAndDismiss(
  WidgetTester tester, {
  required Finder action,
  required Finder surface,
}) async {
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
  expect(surface, findsOneWidget);
  Navigator.of(tester.element(surface)).pop();
  await tester.pumpAndSettle();
}

void _dismiss(WidgetTester tester, Key key) {
  final surface = find.byKey(key);
  expect(surface, findsOneWidget);
  Navigator.of(tester.element(surface)).pop();
}

Future<void> _pumpUntilFound(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 40 && finder.evaluate().isEmpty; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
  expect(finder, findsOneWidget);
}
