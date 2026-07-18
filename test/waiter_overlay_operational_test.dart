import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/models/pos_table.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/core/services/restaurant_cutoff_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/admin/providers/menu_provider.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/order/order_model.dart';
import 'package:globos_pos_system/features/order/order_provider.dart';
import 'package:globos_pos_system/features/table/table_provider.dart';
import 'package:globos_pos_system/features/waiter/waiter_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '7f6c9d22-6d84-4c7f-b923-79c81c4015d1';
const _occupiedTableId = 'waiter-table-a1';
const _availableTableId = 'waiter-table-a2';

const _authState = PosAuthState(
  role: 'waiter',
  storeId: _storeId,
  primaryStoreId: _storeId,
  accessibleStores: [AccessibleStore(id: _storeId, name: 'GLOBOS Nguyễn Huệ')],
);

class _AuthNotifier extends AuthNotifier {
  _AuthNotifier() : super() {
    state = _authState;
  }

  @override
  Future<void> logout() async {}

  @override
  Future<void> setActiveStore(String storeId) async {}
}

class _TableNotifier extends WaiterTableNotifier {
  _TableNotifier() {
    state = const WaiterTableState(
      tables: [
        PosTable(
          id: _occupiedTableId,
          storeId: _storeId,
          tableNumber: 'A1',
          seatCount: 4,
          status: 'occupied',
          floorLabel: 'Ground',
          layoutX: 0.06,
          layoutY: 0.08,
          layoutW: 0.38,
          layoutH: 0.34,
          layoutSortOrder: 1,
        ),
        PosTable(
          id: _availableTableId,
          storeId: _storeId,
          tableNumber: 'A2',
          seatCount: 6,
          status: 'available',
          floorLabel: 'Ground',
          layoutX: 0.54,
          layoutY: 0.08,
          layoutW: 0.38,
          layoutH: 0.34,
          layoutSortOrder: 2,
        ),
      ],
    );
  }

  @override
  Future<void> loadTables(String storeId, {bool showLoading = true}) async {}
}

class _MenuNotifier extends MenuNotifier {
  _MenuNotifier() : super(_storeId) {
    state = const MenuState(
      categories: AsyncValue.data([
        {'id': 'category-main', 'name': 'Món chính'},
      ]),
      items: AsyncValue.data([
        {
          'id': 'menu-pho',
          'category_id': 'category-main',
          'name': 'Phở bò đặc biệt',
          'price': 85000,
          'is_available': true,
        },
      ]),
      selectedCategoryId: 'category-main',
    );
  }

  @override
  Future<void> fetchAll() async {}

  @override
  Future<void> fetchCategories() async {}

  @override
  Future<void> fetchItems() async {}
}

class _OrderNotifier extends OrderNotifier {
  static final _activeOrder = Order(
    id: 'order-a1-active',
    tableId: _occupiedTableId,
    status: 'confirmed',
    createdAt: DateTime(2026, 7, 18, 12),
    guestCount: 2,
    items: const [
      OrderItem(
        id: 'order-item-pho',
        menuItemId: 'menu-pho',
        label: 'Phở bò đặc biệt',
        unitPrice: 85000,
        quantity: 1,
        status: 'pending',
        itemType: 'menu',
      ),
    ],
  );

  _OrderNotifier() {
    state = OrderState(activeOrder: _activeOrder);
  }

  int guestCountUpdates = 0;
  int transfers = 0;
  int quantityEdits = 0;

  @override
  void clearSession() {}

  @override
  Future<void> loadActiveOrder(
    String tableId,
    String storeId, {
    bool syncOffline = true,
  }) async {
    state = OrderState(activeOrder: _activeOrder.copyWith(tableId: tableId));
  }

  @override
  Future<void> updateGuestCount(
    String orderId,
    String storeId,
    int guestCount,
  ) async {
    guestCountUpdates += 1;
    state = state.copyWith(
      activeOrder: state.activeOrder?.copyWith(guestCount: guestCount),
    );
  }

  @override
  Future<void> transferOrderTable(
    String orderId,
    String storeId,
    String newTableId,
  ) async {
    transfers += 1;
    state = state.copyWith(
      activeOrder: state.activeOrder?.copyWith(tableId: newTableId),
    );
  }

  @override
  Future<void> editOrderItemQuantity(
    String itemId,
    String storeId,
    int newQuantity,
  ) async {
    quantityEdits += 1;
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

  testWidgets('all six Waiter and order overlays execute from live controls', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final orderNotifier = _OrderNotifier();
    final router = GoRouter(
      initialLocation: '/waiter',
      routes: [
        GoRoute(path: '/waiter', builder: (_, __) => const WaiterScreen()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _AuthNotifier()),
          connectivityProvider.overrideWith((ref) => Stream.value(true)),
          waiterTableProvider.overrideWith((ref) => _TableNotifier()),
          menuProvider.overrideWith((ref, storeId) => _MenuNotifier()),
          orderProvider.overrideWith((ref) => orderNotifier),
          restaurantNameProvider.overrideWith(
            (ref, storeId) async => 'GLOBOS Nguyễn Huệ',
          ),
          restaurantSettingsProvider.overrideWith(
            (ref, storeId) async => const StoreSettings(
              operationMode: 'standard',
              perPersonCharge: null,
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

    await tester.tap(find.byKey(const Key('waiter_staff_meal_action')));
    await tester.pumpAndSettle();
    final staffMealDialog = find.byKey(const Key('waiter_staff_meal_dialog'));
    expect(staffMealDialog, findsOneWidget);
    await tester.tap(
      find.descendant(
        of: staffMealDialog,
        matching: find.byIcon(Icons.add_circle_outline),
      ),
    );
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(
            find.byKey(const Key('waiter_staff_meal_submit')),
          )
          .onPressed,
      isNotNull,
    );
    Navigator.of(tester.element(staffMealDialog)).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('A2'));
    await tester.pumpAndSettle();
    final initialGuestDialog = find.byKey(
      const Key('waiter_guest_count_dialog'),
    );
    expect(initialGuestDialog, findsOneWidget);
    Navigator.of(tester.element(initialGuestDialog)).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.text('A1'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('waiter-empty-detail')), findsNothing);
    expect(orderNotifier.state.activeOrder, isNotNull);
    expect(
      find.byKey(const Key('order_cancel_order_direct_action_compact')),
      findsOneWidget,
    );

    await tester.tap(
      find.byKey(const Key('order_guest_count_edit_action_compact')),
    );
    await tester.pumpAndSettle();
    final guestDialog = find.byKey(const Key('waiter_guest_count_dialog'));
    expect(guestDialog, findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('waiter_guest_count_input')),
      '3',
    );
    await tester.tap(find.byKey(const Key('waiter_guest_count_confirm')));
    await tester.pumpAndSettle();
    expect(orderNotifier.guestCountUpdates, 1);

    await tester.tap(
      find.byKey(const Key('order_current_ticket_detail_action_compact')),
    );
    await tester.pumpAndSettle();
    final ticketSheet = find.byKey(const Key('order_current_ticket_sheet'));
    expect(ticketSheet, findsOneWidget);
    await tester.tap(
      find.byKey(const Key('order_current_ticket_edit_qty_order-item-pho')),
    );
    await tester.pumpAndSettle();
    final quantityDialog = find.byKey(const Key('order_edit_quantity_dialog'));
    expect(quantityDialog, findsOneWidget);
    await tester.enterText(
      find.descendant(of: quantityDialog, matching: find.byType(TextField)),
      '2',
    );
    await tester.tap(
      find.descendant(of: quantityDialog, matching: find.byType(FilledButton)),
    );
    await tester.pumpAndSettle();
    expect(orderNotifier.quantityEdits, 1);

    await tester.tap(
      find.byKey(const Key('order_cancel_order_direct_action_compact')),
    );
    await tester.pumpAndSettle();
    final cancelDialog = find.byKey(const Key('waiter_cancel_order_dialog'));
    expect(cancelDialog, findsOneWidget);
    Navigator.of(tester.element(cancelDialog)).pop(false);
    await tester.pumpAndSettle();

    final l10n = AppLocalizations.of(
      tester.element(find.byKey(const Key('dashboard_root'))),
    )!;
    await tester.tap(
      find.byKey(const Key('order_transfer_menu_action_compact')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.orderWorkspaceMove).last);
    await tester.pumpAndSettle();
    final transferDialog = find.byKey(
      const Key('waiter_transfer_table_dialog'),
    );
    expect(transferDialog, findsOneWidget);
    await tester.tap(
      find.descendant(of: transferDialog, matching: find.byType(ListTile)),
    );
    await tester.pumpAndSettle();
    expect(orderNotifier.transfers, 1);
    expect(tester.takeException(), isNull);
  });
}
