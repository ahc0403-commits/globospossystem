import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/payment_method_contract.dart';
import 'package:globos_pos_system/core/services/bank_transfer_alert_service.dart';
import 'package:globos_pos_system/core/services/bank_transfer_alert_sound.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/core/services/digital_receipt_service.dart';
import 'package:globos_pos_system/core/services/menu_service.dart';
import 'package:globos_pos_system/core/services/payment_proof_service.dart';
import 'package:globos_pos_system/core/services/payment_service.dart';
import 'package:globos_pos_system/core/services/restaurant_cutoff_service.dart';
import 'package:globos_pos_system/core/models/pos_table.dart';
import 'package:globos_pos_system/core/models/fulfillment_mode.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/cashier/cashier_screen.dart';
import 'package:globos_pos_system/features/digital_receipt/digital_receipt_model.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_staff_service.dart';
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
      label: '소고기 쌀국수',
      nameKo: '소고기 쌀국수',
      nameVi: 'Phở bò đặc biệt',
      nameEn: 'Special beef pho',
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
  fixedChargeTotal: 0,
  discountTotal: 0,
  vatTotal: 10370.37,
  totalAmount: 140000,
  paidTotal: 0,
  paymentCount: 0,
  remainingDue: 140000,
  createdAt: DateTime(2026, 7, 18, 12),
);

final _cashierOrderB = CashierOrder(
  orderId: 'cashier-order-b2',
  tableNumber: 'B2',
  tableId: 'table-b2',
  status: 'serving',
  orderPurpose: 'customer',
  orderSource: 'qr',
  items: const [
    OrderItem(
      id: 'cashier-item-b2',
      menuItemId: 'menu-b2',
      label: 'Bánh xèo',
      unitPrice: 80000,
      quantity: 1,
      status: 'ready',
      itemType: 'menu_item',
    ),
  ],
  menuSubtotal: 80000,
  serviceChargeTotal: 0,
  serviceItemTotal: 0,
  fixedChargeTotal: 0,
  discountTotal: 0,
  vatTotal: 5925.93,
  totalAmount: 80000,
  paidTotal: 0,
  paymentCount: 0,
  remainingDue: 80000,
  createdAt: DateTime(2026, 7, 18, 12, 5),
);

final _paperlessCashierOrder = CashierOrder(
  orderId: _orderId,
  tableNumber: 'A1',
  tableId: 'table-a1',
  status: 'serving',
  orderPurpose: 'customer',
  orderSource: 'qr',
  fulfillmentMode: FulfillmentMode.paperless,
  emergencyModeActive: true,
  unservedQuantity: 1,
  floorServedQuantityByItemId: const {
    'cashier-item-pho': 1,
    'cashier-item-coffee': 0,
  },
  fulfillmentProgressByItemId: const {
    'cashier-item-coffee': [
      CashierFulfillmentProgress(
        fulfillmentItemId: 'progress-coffee-base',
        orderItemId: 'cashier-item-coffee',
        lineKey: 'base',
        sourceKind: 'order_item',
        fulfillmentRoute: 'kitchen_tray_floor',
        nameKo: '커피 세트',
        nameVi: 'Bộ cà phê',
        nameEn: 'Coffee set',
        orderedQuantity: 1,
        floorServedQuantity: 1,
      ),
      CashierFulfillmentProgress(
        fulfillmentItemId: 'progress-cola',
        orderItemId: 'cashier-item-coffee',
        lineKey: 'combo:cola',
        sourceKind: 'combo_component',
        fulfillmentRoute: 'floor_direct',
        nameKo: '콜라',
        nameVi: 'Coca-Cola',
        nameEn: 'Cola',
        orderedQuantity: 1,
        floorServedQuantity: 0,
      ),
    ],
  },
  items: const [
    OrderItem(
      id: 'cashier-item-pho',
      menuItemId: 'menu-pho',
      label: '소고기 쌀국수',
      nameVi: 'Phở bò đặc biệt',
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
  fixedChargeTotal: 0,
  discountTotal: 0,
  vatTotal: 10370.37,
  totalAmount: 140000,
  paidTotal: 0,
  paymentCount: 0,
  remainingDue: 140000,
  createdAt: DateTime(2026, 8, 12, 8),
);

class _AuthNotifier extends AuthNotifier {
  _AuthNotifier([PosAuthState initialState = _authState]) : super() {
    state = initialState;
  }

  @override
  Future<void> logout() async {}
}

class _PaymentNotifier extends PaymentNotifier {
  _PaymentNotifier({
    bool includeSecondOrder = false,
    this.completeOrdersOnPayment = false,
    CashierOrder? initialOrder,
  }) {
    state = PaymentState(
      orders: [
        initialOrder ?? _cashierOrder,
        if (includeSecondOrder) _cashierOrderB,
      ],
    );
  }

  final bool completeOrdersOnPayment;
  int cancelledOrders = 0;
  int cancelledItems = 0;
  int restoredOrders = 0;
  int restoredItems = 0;
  int serviceItemMutations = 0;
  int? confirmedWetTissueQuantity;
  String? processedMethod;
  Map<String, int>? combinedWetTissueQuantities;
  int combinedPaymentDisplayCalls = 0;
  double? combinedPaymentDisplayTotal;
  int combinedReceiptDisplayCalls = 0;

  @override
  Future<void> loadOrders(String storeId) async {}

  @override
  Future<bool> showCombinedReceiptOnCustomerDisplay({
    required String storeId,
    required String combinedPaymentGroupId,
    required String receiptId,
  }) async {
    combinedReceiptDisplayCalls += 1;
    return true;
  }

  @override
  Future<List<QrOrderLedgerBatch>> fetchQrOrderLedger(String orderId) async {
    return [
      QrOrderLedgerBatch(
        batchNo: 1,
        createdAt: DateTime(2026, 7, 18, 12),
        items: const [
          QrOrderLedgerItem(
            name: 'Phở bò đặc biệt',
            nameKo: '특선 소고기 쌀국수',
            nameVi: 'Phở bò đặc biệt',
            nameEn: 'Special beef pho',
            quantity: 1,
            unitPrice: 100000,
          ),
        ],
      ),
    ];
  }

  @override
  Future<bool> setWetTissueQuantity({
    required String storeId,
    required String orderId,
    required int quantity,
  }) async {
    confirmedWetTissueQuantity = quantity;
    return true;
  }

  @override
  Future<Map<String, dynamic>?> processPayment(
    String storeId,
    String orderId,
    double amount,
    String method,
  ) async {
    processedMethod = method;
    if (completeOrdersOnPayment) {
      final completedOrder = state.orders.firstWhere(
        (order) => order.orderId == orderId,
      );
      state = state.copyWith(
        orders: state.orders
            .where((order) => order.orderId != orderId)
            .toList(growable: false),
        completedOrders: [...state.completedOrders, completedOrder],
        paymentSuccess: true,
        isProcessing: false,
        clearSelectedOrder: true,
      );
    } else {
      state = state.copyWith(paymentSuccess: true, isProcessing: false);
    }
    return {'id': 'payment-single'};
  }

  @override
  Future<Map<String, dynamic>?> processCombinedTablePayment(
    String storeId,
    List<CashierOrder> orders,
    String method,
  ) async {
    processedMethod = method;
    state = state.copyWith(paymentSuccess: true, isProcessing: false);
    return {
      'group_id': 'combined-group',
      'payments': [
        for (var index = 0; index < orders.length; index++)
          {'id': 'combined-payment-$index'},
      ],
    };
  }

  @override
  Future<bool> showCombinedOnCustomerDisplay({
    required String storeId,
    required List<CashierOrder> orders,
  }) async {
    combinedPaymentDisplayCalls += 1;
    combinedPaymentDisplayTotal = orders.fold<double>(
      0,
      (sum, order) => sum + order.remainingDue,
    );
    return true;
  }

  @override
  Future<bool> prepareCombinedTablePayment({
    required String storeId,
    required Map<String, int> wetTissueQuantities,
  }) async {
    combinedWetTissueQuantities = Map<String, int>.from(wetTissueQuantities);
    return true;
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

  @override
  Future<bool> cancelOrderItem(String itemId, String storeId) async {
    cancelledItems += 1;
    return true;
  }

  @override
  Future<bool> restoreCancelledOrder(String orderId, String storeId) async {
    restoredOrders += 1;
    return true;
  }

  @override
  Future<bool> restoreCancelledOrderItem(String itemId, String storeId) async {
    restoredItems += 1;
    return true;
  }
}

class _TableNotifier extends WaiterTableNotifier {
  _TableNotifier({bool includeSecondOrder = false, int? tableCount}) {
    final effectiveTableCount = tableCount ?? (includeSecondOrder ? 2 : 1);
    state = WaiterTableState(
      tables: [
        for (var index = 0; index < effectiveTableCount; index++)
          PosTable(
            id: index == 0
                ? 'table-a1'
                : index == 1
                ? 'table-b2'
                : 'table-${index + 1}',
            storeId: _storeId,
            tableNumber: index == 0
                ? 'A1'
                : index == 1
                ? 'B2'
                : '${2101 + index}',
            seatCount: 4,
            status: index < 2 ? 'occupied' : 'available',
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
  int combinedReceiptCalls = 0;
  String? combinedPaymentGroupId;

  @override
  Future<Map<String, dynamic>> enqueueReceiptPrintJob({
    required String orderId,
    double? receivedAmount,
    bool reprint = false,
  }) async {
    this.receivedAmount = receivedAmount;
    return {'status': 'done'};
  }

  @override
  Future<Map<String, dynamic>> enqueueCombinedReceiptPrintJob({
    required String combinedPaymentGroupId,
    double? receivedAmount,
    bool reprint = false,
  }) async {
    combinedReceiptCalls += 1;
    this.combinedPaymentGroupId = combinedPaymentGroupId;
    this.receivedAmount = receivedAmount;
    return {'status': 'done'};
  }
}

class _DigitalReceiptService extends DigitalReceiptService {
  int combinedCalls = 0;
  String? combinedPaymentGroupId;

  @override
  Future<DigitalReceiptAccess> ensureAndIssue({
    required String orderId,
    double? receivedAmount,
    double? changeAmount,
  }) async => DigitalReceiptAccess(
    receiptId: 'receipt-$orderId',
    receiptNumber: 'BC-ORDER',
    token: 'order-token',
    publicUrl: 'https://example.test/receipt#token=order-token',
  );

  @override
  Future<DigitalReceiptAccess> ensureCombinedAndIssue({
    required String combinedPaymentGroupId,
    double? receivedAmount,
    double? changeAmount,
  }) async {
    combinedCalls += 1;
    this.combinedPaymentGroupId = combinedPaymentGroupId;
    return const DigitalReceiptAccess(
      receiptId: 'combined-receipt',
      receiptNumber: 'BC-COMBINED',
      token: 'combined-token',
      publicUrl: 'https://example.test/receipt#token=combined-token',
    );
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

class _MenuService extends MenuService {
  final List<Map<String, dynamic>> items = [
    {'id': 'menu-pho', 'name': 'Phở bò đặc biệt', 'is_available': true},
    {'id': 'menu-coffee', 'name': 'Cà phê sữa đá', 'is_available': false},
  ];
  final List<(String, bool)> availabilityChanges = [];

  @override
  Future<List<Map<String, dynamic>>> fetchItems(String storeId) async => [
    for (final item in items) Map<String, dynamic>.from(item),
  ];

  @override
  Future<void> toggleAvailability(String itemId, bool isAvailable) async {
    availabilityChanges.add((itemId, isAvailable));
  }
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

  testWidgets('cashier item rows show only the selected menu language', (
    tester,
  ) async {
    await _pumpCashier(tester);
    await _selectOrder(tester);

    expect(find.text('Phở bò đặc biệt'), findsOneWidget);
    expect(find.text('소고기 쌀국수'), findsNothing);
    expect(find.text('Special beef pho'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('paperless cashier shows which menu items were served', (
    tester,
  ) async {
    await _pumpCashier(tester, initialOrder: _paperlessCashierOrder);
    await _selectOrder(tester);

    expect(
      find.byKey(const Key('cashier_item_fulfillment_cashier-item-pho')),
      findsOneWidget,
    );
    expect(find.text('Đã phục vụ 1 / 1'), findsOneWidget);
    expect(find.text('Đã phục vụ 0 / 1'), findsOneWidget);
    expect(
      find.byKey(const Key('cashier_fulfillment_part_progress-cola')),
      findsOneWidget,
    );
    expect(find.text('Coca-Cola'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cashier can use manager-approved service item controls without extra permissions',
    (tester) async {
      await _pumpCashier(
        tester,
        authState: const PosAuthState(
          role: 'cashier',
          storeId: _storeId,
          primaryStoreId: _storeId,
          accessibleStores: [
            AccessibleStore(id: _storeId, name: 'GLOBOS Nguyễn Huệ'),
          ],
        ),
      );
      await _selectOrder(tester);

      expect(find.byKey(const Key('cashier_discount_button')), findsOneWidget);
      final serviceItemAction = find.byKey(
        const Key('cashier_service_item_action_cashier-item-pho'),
      );
      expect(serviceItemAction, findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(serviceItemAction).onPressed,
        isNotNull,
      );

      await tester.ensureVisible(
        find.byKey(const Key('cashier_discount_button')),
      );
      await tester.tap(find.byKey(const Key('cashier_discount_button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cashier_discount_mode_select')));
      await tester.pumpAndSettle();
      expect(find.text('Tặng miễn phí món đã chọn'), findsOneWidget);
      await tester.tap(find.text('Tặng miễn phí món đã chọn'));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('cashier_discount_service_item_select')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('discount mode can provide one selected menu item for free', (
    tester,
  ) async {
    final harness = await _pumpCashier(tester);
    await _selectOrder(tester);

    final discountButton = find.byKey(const Key('cashier_discount_button'));
    await tester.ensureVisible(discountButton);
    await tester.tap(discountButton);
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('cashier_discount_mode_select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Tặng miễn phí món đã chọn').last);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('cashier_discount_service_item_select')),
      findsOneWidget,
    );
    expect(find.text('Giá trị giảm'), findsNothing);
    expect(find.text('Thêm chứng từ'), findsNothing);

    await tester.tap(
      find.byKey(const Key('cashier_discount_service_item_select')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Phở bò đặc biệt × 1 · ₫100.000').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('cashier_discount_reason_input')),
      'Guest recovery',
    );
    await tester.enterText(
      find.byKey(const Key('cashier_discount_pin_input')),
      '1234',
    );
    await tester.tap(find.byKey(const Key('cashier_discount_apply_button')));
    await tester.pumpAndSettle();

    expect(harness.notifier.serviceItemMutations, 1);
    expect(find.byKey(const Key('cashier_discount_dialog')), findsNothing);
    expect(find.text('Đã đánh dấu món phục vụ.'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('order number opens the customer QR order ledger', (
    tester,
  ) async {
    await _pumpCashier(tester);
    await _selectOrder(tester);

    final ledgerAction = find.byKey(
      const Key('cashier_order_ledger_action_$_orderId'),
    );
    await tester.ensureVisible(ledgerAction);
    await tester.tap(ledgerAction);
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('cashier_qr_order_ledger_dialog')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('cashier_qr_order_ledger_batch_1')),
      findsOneWidget,
    );
    expect(find.text('Phở bò đặc biệt × 1'), findsOneWidget);
    expect(find.text('특선 소고기 쌀국수 × 1'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('cashier fits all 44 tables inside the responsive overview', (
    tester,
  ) async {
    await _pumpCashier(
      tester,
      tableCount: 44,
      physicalSize: const Size(1440, 900),
    );

    expect(
      find.byKey(const Key('floor_responsive_table_grid')),
      findsOneWidget,
    );
    final lastTable = find.byKey(const ValueKey('responsive_table_table-44'));
    expect(lastTable, findsOneWidget);
    expect(tester.getBottomRight(lastTable).dy, lessThanOrEqualTo(900));
    expect(tester.takeException(), isNull);
  });

  testWidgets('dense desktop checkout keeps payment controls in one viewport', (
    tester,
  ) async {
    await _pumpCashier(tester, physicalSize: const Size(1600, 820));
    await tester.tap(find.byKey(const Key('cashier_order_$_orderId')));
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('cashier_wet_tissue_confirm')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find
          .byKey(const Key('cashier_method_tile_$paymentMethodService'))
          .hitTestable(),
      findsOneWidget,
    );
    final splitButton = find.byKey(const Key('cashier_split_payment_button'));
    expect(splitButton.hitTestable(), findsOneWidget);
    expect(
      find.byKey(const Key('payment_submit_button')).hitTestable(),
      findsOneWidget,
    );
    expect(
      tester.getBottomRight(find.byKey(const Key('payment_submit_button'))).dy,
      lessThanOrEqualTo(820),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('Galaxy Tab keeps item cancellation visible and undoable', (
    tester,
  ) async {
    final harness = await _pumpCashier(
      tester,
      physicalSize: const Size(800, 1280),
    );
    await _selectOrder(tester);

    expect(find.byKey(const Key('cashier_tablet_split_view')), findsOneWidget);
    expect(
      find.byKey(const Key('cashier_pending_payment_list')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('cashier_completed_order_history')),
      findsOneWidget,
    );
    expect(find.byKey(const Key('cashier_payment_surface')), findsOneWidget);

    final cancelItem = find.byKey(
      const Key('cashier_cancel_order_item_cashier-item-pho'),
    );
    await tester.ensureVisible(cancelItem);
    expect(cancelItem.hitTestable(), findsOneWidget);
    expect(tester.getBottomRight(cancelItem).dx, lessThanOrEqualTo(800));

    await tester.tap(cancelItem);
    await tester.pumpAndSettle();
    expect(harness.notifier.cancelledItems, 1);
    expect(find.text('Hoàn tác'), findsOneWidget);

    await tester.tap(find.text('Hoàn tác'));
    await tester.pumpAndSettle();
    expect(harness.notifier.restoredItems, 1);
    expect(find.text('Đã khôi phục món bị hủy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Galaxy Tab completes cancel undo payment and completed-history flow',
    (tester) async {
      final harness = await _pumpCashier(
        tester,
        physicalSize: const Size(800, 1280),
        completeOrdersOnPayment: true,
      );
      await _selectOrder(tester);

      final cancelItem = find.byKey(
        const Key('cashier_cancel_order_item_cashier-item-pho'),
      );
      await tester.ensureVisible(cancelItem);
      await tester.tap(cancelItem);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Hoàn tác'));
      await tester.pumpAndSettle();

      final cashMethod = find.byKey(
        const Key('cashier_method_tile_$paymentMethodCash'),
      );
      await tester.ensureVisible(cashMethod);
      await tester.tap(cashMethod);
      await tester.pump();
      final submit = find.byKey(const Key('payment_submit_button'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const Key('cashier_cash_received_input')),
        '200000',
      );
      await tester.pump();
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
      _dismiss(tester, const Key('cashier_payment_completion_dialog'));
      await tester.pumpAndSettle();

      final completedHistory = find.byKey(
        const Key('cashier_completed_order_history'),
      );
      expect(harness.notifier.cancelledItems, 1);
      expect(harness.notifier.restoredItems, 1);
      expect(harness.notifier.processedMethod, paymentMethodCash);
      expect(completedHistory, findsOneWidget);
      expect(
        find.descendant(of: completedHistory, matching: find.text('Bàn A1')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancelled order exposes the same undo path', (tester) async {
    final harness = await _pumpCashier(tester);
    await _selectOrder(tester);

    final cancelOrder = find.byKey(const Key('cashier_cancel_order_action'));
    await tester.ensureVisible(cancelOrder);
    await tester.tap(cancelOrder);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('cashier_cancel_order_confirm_button')),
    );
    await tester.pumpAndSettle();

    expect(harness.notifier.cancelledOrders, 1);
    expect(find.text('Hoàn tác'), findsOneWidget);
    await tester.tap(find.text('Hoàn tác'));
    await tester.pumpAndSettle();
    expect(harness.notifier.restoredOrders, 1);
    expect(find.text('Đã khôi phục đơn bị hủy'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'wet-tissue quantity is confirmed before cashier payment methods unlock',
    (tester) async {
      final harness = await _pumpCashier(tester);
      await tester.tap(find.byKey(const Key('cashier_order_$_orderId')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('cashier_wet_tissue_required_hint')),
        findsOneWidget,
      );
      final cashMethod = find.byKey(
        const Key('cashier_method_tile_$paymentMethodCash'),
      );
      final cashMethodInkWell = find.descendant(
        of: cashMethod,
        matching: find.byType(InkWell),
      );
      expect(tester.widget<InkWell>(cashMethodInkWell).onTap, isNull);
      expect(harness.notifier.processedMethod, isNull);

      final increment = find.byKey(const Key('cashier_wet_tissue_increment'));
      await tester.ensureVisible(increment);
      await tester.tap(increment);
      await tester.pump();
      await tester.tap(increment);
      await tester.pump();
      expect(find.text('2'), findsOneWidget);
      expect(find.text('₫4.000'), findsOneWidget);

      await tester.tap(find.byKey(const Key('cashier_wet_tissue_confirm')));
      await tester.pumpAndSettle();
      expect(harness.notifier.confirmedWetTissueQuantity, 2);
      expect(
        find.byKey(const Key('cashier_wet_tissue_required_hint')),
        findsNothing,
      );
    },
  );

  testWidgets('all non-post-payment Cashier overlays open from live controls', (
    tester,
  ) async {
    final harness = await _pumpCashier(tester);
    await _selectOrder(tester);

    await tester.ensureVisible(
      find.byKey(const Key('cashier_sold_out_menu_action')),
    );
    await tester.tap(find.byKey(const Key('cashier_sold_out_menu_action')));
    await tester.pumpAndSettle();
    final soldOutDialog = find.byKey(const Key('cashier_sold_out_dialog'));
    expect(soldOutDialog, findsOneWidget);
    await tester.tap(
      find.byKey(const Key('cashier_menu_availability_menu-pho')),
    );
    await tester.pumpAndSettle();
    expect(harness.menuService.availabilityChanges, [('menu-pho', false)]);
    Navigator.of(tester.element(soldOutDialog)).pop();
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byKey(const Key('payment_submit_button')));
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
    await tester.ensureVisible(
      find.byKey(const Key('cashier_method_tile_$paymentMethodService')),
    );
    await tester.tap(
      find.byKey(const Key('cashier_method_tile_$paymentMethodService')),
    );
    await tester.pump();
    await _openAndDismiss(
      tester,
      action: find.byKey(const Key('payment_submit_button')),
      surface: find.byKey(const Key('cashier_non_revenue_dialog')),
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
      find.byKey(const Key('cashier_method_tile_$paymentMethodBankTransfer')),
    );
    await tester.tap(
      find.byKey(const Key('cashier_method_tile_$paymentMethodBankTransfer')),
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
    expect(harness.notifier.processedMethod, paymentMethodBankTransfer);
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

  testWidgets(
    'combined payment selects multiple tables and confirms wet tissues first',
    (tester) async {
      final harness = await _pumpCashier(
        tester,
        includeSecondOrder: true,
        physicalSize: const Size(1440, 1600),
      );

      await tester.tap(find.byKey(const Key('cashier_combined_payment_mode')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('cashier_combined_order_$_orderId')),
      );
      await tester.tap(
        find.byKey(const Key('cashier_combined_order_cashier-order-b2')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Đã chọn 2 bàn'), findsOneWidget);
      await tester.tap(find.byKey(const Key('cashier_combined_payment_start')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('cashier_combined_payment_dialog')),
        findsOneWidget,
      );

      await tester.tap(
        find.byKey(const Key('cashier_combined_wet_tissue_plus_$_orderId')),
      );
      await tester.tap(
        find.byKey(const Key('cashier_combined_payment_confirm')),
      );
      await tester.pumpAndSettle();

      expect(harness.notifier.combinedWetTissueQuantities, {
        _orderId: 1,
        'cashier-order-b2': 0,
      });
      expect(
        find.byKey(const Key('cashier_combined_payment_method_dialog')),
        findsOneWidget,
      );
      expect(harness.notifier.combinedPaymentDisplayCalls, 1);
      expect(harness.notifier.combinedPaymentDisplayTotal, 220000);
      await tester.tap(
        find.byKey(const Key('cashier_method_dialog_$paymentMethodCash')),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('cashier_combined_cash_tender_dialog')),
        findsOneWidget,
      );
      _dismiss(tester, const Key('cashier_combined_cash_tender_dialog'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'combined payment confirmation can cancel an incorrect table selection',
    (tester) async {
      final harness = await _pumpCashier(
        tester,
        includeSecondOrder: true,
        physicalSize: const Size(1440, 1600),
      );

      await tester.tap(find.byKey(const Key('cashier_combined_payment_mode')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('cashier_combined_order_$_orderId')),
      );
      await tester.tap(
        find.byKey(const Key('cashier_combined_order_cashier-order-b2')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cashier_combined_payment_start')));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('cashier_combined_payment_cancel')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('cashier_combined_payment_dialog')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('cashier_combined_payment_selection_bar')),
        findsNothing,
      );
      expect(
        find.byKey(const Key('cashier_combined_order_$_orderId')),
        findsNothing,
      );
      expect(harness.notifier.combinedPaymentDisplayCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'combined non-cash payment gives paperless orders one group receipt',
    (tester) async {
      final harness = await _pumpCashier(
        tester,
        includeSecondOrder: true,
        initialOrder: _paperlessCashierOrder,
        physicalSize: const Size(1440, 1600),
      );
      await tester.tap(find.byKey(const Key('cashier_combined_payment_mode')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('cashier_combined_order_$_orderId')),
      );
      await tester.tap(
        find.byKey(const Key('cashier_combined_order_cashier-order-b2')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cashier_combined_payment_start')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('cashier_combined_payment_confirm')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('cashier_method_dialog_$paymentMethodCreditCard')),
      );
      await _pumpUntilFound(
        tester,
        find.byKey(const Key('cashier_combined_payment_proof_dialog')),
      );
      _dismiss(tester, const Key('cashier_combined_payment_proof_dialog'));
      await _pumpUntilFound(
        tester,
        find.byKey(const Key('cashier_combined_red_invoice_$_orderId')),
      );
      _dismiss(tester, const Key('cashier_combined_red_invoice_$_orderId'));
      await _pumpUntilFound(
        tester,
        find.byKey(const Key('cashier_combined_red_invoice_cashier-order-b2')),
      );
      _dismiss(
        tester,
        const Key('cashier_combined_red_invoice_cashier-order-b2'),
      );
      await _pumpUntilFound(
        tester,
        find.byKey(const Key('cashier_combined_payment_completion_dialog')),
      );

      expect(harness.notifier.processedMethod, paymentMethodCreditCard);
      expect(harness.proofService.markRequiredCalls, 1);
      expect(harness.paymentService.combinedReceiptCalls, 1);
      expect(harness.paymentService.combinedPaymentGroupId, 'combined-group');
      expect(harness.digitalReceiptService.combinedCalls, 1);
      expect(harness.notifier.combinedReceiptDisplayCalls, 1);
      expect(
        harness.digitalReceiptService.combinedPaymentGroupId,
        'combined-group',
      );
      expect(find.byKey(const Key('cashier_combined_receipt')), findsOneWidget);
      expect(
        find.byKey(const Key('cashier_combined_receipt_qr')),
        findsOneWidget,
      );
      _dismiss(tester, const Key('cashier_combined_payment_completion_dialog'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'combined QR shows one QR for the combined total before payment',
    (tester) async {
      await _pumpCashier(
        tester,
        includeSecondOrder: true,
        physicalSize: const Size(1440, 1600),
      );
      await tester.tap(find.byKey(const Key('cashier_combined_payment_mode')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('cashier_combined_order_$_orderId')),
      );
      await tester.tap(
        find.byKey(const Key('cashier_combined_order_cashier-order-b2')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('cashier_combined_payment_start')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('cashier_combined_payment_confirm')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('cashier_method_dialog_$paymentMethodOther')),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('cashier_combined_qr_payment_dialog')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('cashier_combined_qr_image')),
        findsOneWidget,
      );
      expect(
        find.byKey(const Key('cashier_combined_qr_total')),
        findsOneWidget,
      );
      _dismiss(tester, const Key('cashier_combined_qr_payment_dialog'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('polling fallback shows one bank transfer toast and sound', (
    tester,
  ) async {
    final startedAt = DateTime.now().toUtc();
    final alertService = _MutableBankTransferAlertService([
      BankTransferAlert(
        transactionId: 'historical',
        providerTransactionId: 1,
        amount: 1000,
        gateway: 'Vietcombank',
        receivedAt: startedAt.subtract(const Duration(minutes: 1)),
      ),
    ]);
    final soundService = _RecordingBankTransferAlertSoundService();
    await _pumpCashier(
      tester,
      bankTransferAlertService: alertService,
      bankTransferAlertSoundService: soundService,
      bankTransferAlertPollInterval: const Duration(milliseconds: 20),
    );

    expect(soundService.playCount, 0);
    expect(find.textContaining('1.000 VND'), findsNothing);

    final receivedAt = DateTime.now().toUtc();
    alertService.alerts.addAll([
      BankTransferAlert(
        transactionId: 'new-transfer-1',
        providerTransactionId: 2,
        amount: 42000,
        paymentCode: 'GBTEST42',
        gateway: 'Vietcombank',
        receivedAt: receivedAt,
      ),
      BankTransferAlert(
        transactionId: 'new-transfer-2',
        providerTransactionId: 3,
        amount: 43000,
        paymentCode: 'GBTEST43',
        gateway: 'Vietcombank',
        receivedAt: receivedAt.add(const Duration(milliseconds: 1)),
      ),
      BankTransferAlert(
        transactionId: 'new-transfer-3',
        providerTransactionId: 4,
        amount: 44000,
        paymentCode: 'GBTEST44',
        gateway: 'Vietcombank',
        receivedAt: receivedAt.add(const Duration(milliseconds: 2)),
      ),
    ]);
    await tester.pump(const Duration(milliseconds: 25));
    await tester.pump();

    expect(soundService.playCount, 3);
    expect(soundService.amounts, [42000, 43000, 44000]);
    expect(alertService.acknowledgements, [
      (transactionId: 'new-transfer-1', spoken: false),
      (transactionId: 'new-transfer-1', spoken: true),
      (transactionId: 'new-transfer-2', spoken: false),
      (transactionId: 'new-transfer-2', spoken: true),
      (transactionId: 'new-transfer-3', spoken: false),
      (transactionId: 'new-transfer-3', spoken: true),
    ]);
    expect(find.textContaining('44.000 VND'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 25));
    expect(soundService.playCount, 3);
  });

  testWidgets('cashier always exposes the direct delivery desk entry', (
    tester,
  ) async {
    await _pumpCashier(tester);

    final entry = find.byKey(const Key('cashier_direct_orders_entry'));
    expect(entry, findsOneWidget);
    await tester.tap(entry);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('direct-order-desk-route')), findsOneWidget);
  });

  testWidgets('cashier always exposes delivery status even when empty', (
    tester,
  ) async {
    await _pumpCashier(tester);

    final deliveryTab = find.byKey(const Key('cashier_delivery_status_tab'));
    expect(deliveryTab, findsOneWidget);
    await tester.tap(deliveryTab);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('cashier_delivery_status')), findsOneWidget);
    expect(find.text('Không có đơn đang giao'), findsOneWidget);
  });

  testWidgets('cashier shows active direct delivery progress', (tester) async {
    await _pumpCashier(
      tester,
      deliveryTickets: const [
        {'id': 'ticket-1', 'pickup_code': 'D12345678', 'status': 'preparing'},
      ],
    );

    expect(find.byKey(const Key('cashier_delivery_status')), findsOneWidget);
    expect(find.text('#D12345678'), findsOneWidget);
    expect(find.text('Đang chuẩn bị'), findsOneWidget);
  });
}

class _DirectOrderStaffService extends DirectOrderStaffService {
  const _DirectOrderStaffService(this.tickets);

  final List<Map<String, dynamic>> tickets;

  @override
  Future<List<Map<String, dynamic>>> listTickets({
    required String storeId,
    List<String>? statuses,
  }) async => tickets;
}

class _CashierHarness {
  const _CashierHarness({
    required this.notifier,
    required this.proofService,
    required this.paymentService,
    required this.menuService,
    required this.digitalReceiptService,
  });

  final _PaymentNotifier notifier;
  final _PaymentProofService proofService;
  final _PaymentService paymentService;
  final _MenuService menuService;
  final _DigitalReceiptService digitalReceiptService;
}

Future<_CashierHarness> _pumpCashier(
  WidgetTester tester, {
  PosAuthState authState = _authState,
  bool includeSecondOrder = false,
  bool completeOrdersOnPayment = false,
  CashierOrder? initialOrder,
  int? tableCount,
  Size physicalSize = const Size(1440, 1000),
  BankTransferAlertService? bankTransferAlertService,
  BankTransferAlertSoundService? bankTransferAlertSoundService,
  Duration bankTransferAlertPollInterval = const Duration(seconds: 2),
  List<Map<String, dynamic>> deliveryTickets = const [],
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = physicalSize;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final notifier = _PaymentNotifier(
    includeSecondOrder: includeSecondOrder,
    completeOrdersOnPayment: completeOrdersOnPayment,
    initialOrder: initialOrder,
  );
  final proofService = _PaymentProofService();
  final paymentService = _PaymentService();
  final menuService = _MenuService();
  final digitalReceiptService = _DigitalReceiptService();
  final directOrderStaffService = _DirectOrderStaffService(deliveryTickets);
  final router = GoRouter(
    initialLocation: '/cashier',
    routes: [
      GoRoute(
        path: '/cashier',
        builder: (_, __) => CashierScreen(
          paymentProofServiceOverride: proofService,
          paymentServiceOverride: paymentService,
          restaurantCutoffServiceOverride: _CutoffService(),
          menuServiceOverride: menuService,
          digitalReceiptServiceOverride: digitalReceiptService,
          directOrderStaffServiceOverride: directOrderStaffService,
          deliveryStatusPollInterval: const Duration(hours: 1),
          bankTransferAlertServiceOverride:
              bankTransferAlertService ?? _NoopBankTransferAlertService(),
          bankTransferAlertSoundServiceOverride: bankTransferAlertSoundService,
          bankTransferAlertPollInterval: bankTransferAlertPollInterval,
        ),
      ),
      GoRoute(
        path: '/payments/:id',
        builder: (_, __) => const Scaffold(
          key: Key('payment-result-route'),
          body: SizedBox.shrink(),
        ),
      ),
      GoRoute(
        path: '/cashier/direct-orders',
        builder: (_, __) => const Scaffold(
          key: Key('direct-order-desk-route'),
          body: SizedBox.shrink(),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _AuthNotifier(authState)),
        connectivityProvider.overrideWith((ref) => Stream.value(true)),
        paymentProvider.overrideWith((ref) => notifier),
        waiterTableProvider.overrideWith(
          (ref) => _TableNotifier(
            includeSecondOrder: includeSecondOrder,
            tableCount: tableCount,
          ),
        ),
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
    menuService: menuService,
    digitalReceiptService: digitalReceiptService,
  );
}

Future<void> _selectOrder(WidgetTester tester) async {
  await tester.tap(find.byKey(const Key('cashier_order_$_orderId')));
  await tester.pumpAndSettle();
  expect(find.byKey(const Key('cashier_payment_surface')), findsOneWidget);
  expect(
    find.byKey(const Key('cashier_wet_tissue_required_hint')),
    findsOneWidget,
  );
  final confirm = find.byKey(const Key('cashier_wet_tissue_confirm'));
  await tester.ensureVisible(confirm);
  await tester.tap(confirm);
  await tester.pumpAndSettle();
  expect(
    find.byKey(const Key('cashier_wet_tissue_required_hint')),
    findsNothing,
  );
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

class _NoopBankTransferAlertService extends BankTransferAlertService {
  @override
  Future<void> registerPollingDevice(String storeId) async {}

  @override
  Future<bool> acknowledge(
    String transactionId, {
    required bool spoken,
  }) async => true;

  @override
  Future<List<BankTransferAlert>> fetchAfter(
    String storeId,
    BankTransferAlertCursor cursor, {
    int limit = 100,
  }) async => const [];

  @override
  Future<BankTransferAlertCursor?> loadCursor(String storeId) async => null;

  @override
  Future<void> saveCursor(
    String storeId,
    BankTransferAlertCursor cursor,
  ) async {}
}

class _MutableBankTransferAlertService extends BankTransferAlertService {
  _MutableBankTransferAlertService(this.alerts);

  final List<BankTransferAlert> alerts;
  final List<({String transactionId, bool spoken})> acknowledgements = [];

  @override
  Future<void> registerPollingDevice(String storeId) async {}

  @override
  Future<bool> acknowledge(String transactionId, {required bool spoken}) async {
    acknowledgements.add((transactionId: transactionId, spoken: spoken));
    return true;
  }

  @override
  Future<List<BankTransferAlert>> fetchAfter(
    String storeId,
    BankTransferAlertCursor cursor, {
    int limit = 100,
  }) async => alerts.where(cursor.isBefore).take(limit).toList();

  @override
  Future<BankTransferAlertCursor?> loadCursor(String storeId) async => null;

  @override
  Future<void> saveCursor(
    String storeId,
    BankTransferAlertCursor cursor,
  ) async {}
}

class _RecordingBankTransferAlertSoundService
    extends BankTransferAlertSoundService {
  int playCount = 0;
  final List<int> amounts = [];

  @override
  Future<void> prepare() async {}

  @override
  Future<void> play({required int amount}) async {
    playCount += 1;
    amounts.add(amount);
  }
}
