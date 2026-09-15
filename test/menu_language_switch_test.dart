import 'package:globos_pos_system/features/kitchen/kitchen_provider.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/i18n/menu_localization.dart';
import 'package:globos_pos_system/core/models/pos_table.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/core/services/menu_service.dart';
import 'package:globos_pos_system/features/admin/providers/menu_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/cashier/cashier_sold_out_dialog.dart';
import 'package:globos_pos_system/features/order/order_model.dart';
import 'package:globos_pos_system/features/order/order_provider.dart';
import 'package:globos_pos_system/features/report/bm_menu_exception_history.dart';
import 'package:globos_pos_system/features/report/menu_sales_analytics.dart';
import 'package:globos_pos_system/features/receipt_ledger/receipt_ledger_model.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:globos_pos_system/widgets/order_workspace.dart';

const _names = [
  {
    'name': '돌솥 불고기 비빔밥',
    'name_ko': '돌솥 불고기 비빔밥',
    'name_en': 'Stone Pot Bulgogi Bibimbap',
    'name_vi': 'Cơm Trộn Nồi Đá Bulgogi',
  },
  {
    'name': '밥',
    'name_ko': '밥',
    'name_en': 'Steamed Rice',
    'name_vi': 'Cơm Trắng',
  },
  {
    'name': '생수',
    'name_ko': '생수',
    'name_en': 'Dasani Water',
    'name_vi': 'Nước Suối',
  },
];

class _HistoryLoader implements BmMenuExceptionHistoryLoader {
  _HistoryLoader(this.kind);
  final String kind;
  int requests = 0;
  @override
  Future<BmMenuExceptionHistoryPage> fetch({
    required DateTime startDate,
    required DateTime endDate,
    required BmMenuHistoryType historyType,
    required bool includeReversals,
    required int page,
    String? storeId,
    String? search,
    DateTime? snapshotAt,
  }) async {
    requests++;
    return BmMenuExceptionHistoryPage.fromJson({
      'items': [
        {
          'source_kind': kind,
          'event_type': switch (kind) {
            'staff_meal' => 'staff_meal_created',
            'service' => 'service_marked',
            _ => 'item_cancelled',
          },
          'event_id': 'event-1',
          'event_at': '2026-09-15T14:03:00Z',
          'store_id': 'store-1',
          'store_name': 'BunsikClub Binh Thanh',
          'order_id': 'order-1',
          'order_number': '11036',
          'table_number': '2220',
          'item_name': _names.map((name) => name['name']).join(', '),
          'item_names': _names,
          'quantity': 3,
          'reference_amount': 96000,
          'cancelled_amount': kind == 'cancellation' ? 96000 : null,
          'current_state': 'completed',
          'actor_name': 'Unknown actor',
        },
      ],
      'summary': {'total_rows': 1},
      'page': 0,
      'page_size': 50,
      'has_more': false,
    });
  }

  @override
  Future<BmOriginalOrderDetail> fetchOrderDetail({
    required String orderId,
  }) async => BmOriginalOrderDetail.fromJson({
    'order_id': orderId,
    'order_number': '11036',
    'store_id': 'store-1',
    'store_name': 'BunsikClub Binh Thanh',
    'created_at': '2026-09-15T14:03:00Z',
    'status': 'completed',
    'items': [
      for (var i = 0; i < _names.length; i++)
        {
          ..._names[i],
          'id': '$i',
          'quantity': 1,
          'unit_price': 32000,
          'reference_amount': 32000,
          'status': 'served',
        },
    ],
  });
}

class _MenuService extends MenuService {
  @override
  Future<List<Map<String, dynamic>>> fetchItems(String storeId) async => [
    for (var i = 0; i < _names.length; i++)
      {..._names[i], 'id': '$i', 'is_available': true},
  ];
  @override
  Future<void> toggleAvailability(String itemId, bool isAvailable) async {}
}

Widget _app(ValueNotifier<Locale> locale, Widget home) => ProviderScope(
  overrides: [
    bmMenuHistoryRoleProvider.overrideWith((ref) => 'brand_admin'),
    connectivityProvider.overrideWith((ref) => Stream.value(true)),
  ],
  child: ValueListenableBuilder<Locale>(
    valueListenable: locale,
    builder: (context, value, _) => MaterialApp(
      locale: value,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      home: home,
    ),
  ),
);

void main() {
  test('data names choose selected locale and preserve legacy identity', () {
    for (final code in ['en', 'vi', 'ko']) {
      expect(localizedMenuName(_names.first, code), _names.first['name_$code']);
      expect(
        localizedMenuName({
          'name': 'Legacy historical menu',
          'name_en': '  ',
        }, code),
        'Legacy historical menu',
      );
      final receipt = ReceiptLedgerItem.fromJson({
        ..._names.first,
        'quantity': 2,
        'unit_price': 50000,
      });
      expect(receipt.localizedName(code), _names.first['name_$code']);
      expect(receipt.lineTotal, 100000);
      final report = MenuSalesRow.fromJson({
        ..._names.first,
        'display_name': 'Historical name',
        'menu_key': 'stable-id',
        'menu_sales_amount': 100000,
      });
      expect(report.localizedName(code), _names.first['name_$code']);
      expect(report.displayName, 'Historical name');
      expect(report.menuSalesAmount, 100000);
    }
    for (final code in ['en', 'vi', 'ko']) {
      final data = {
        ..._names.first,
        'label': _names.first['name'],
        'quantity': 2,
      };
      expect(
        OrderComboComponent.fromJson(data).localizedName(code),
        _names.first['name_$code'],
      );
      expect(
        KitchenComboComponent.fromJson(data).localizedName(code),
        _names.first['name_$code'],
      );
      expect(OrderComboComponent.fromJson(data).displayQuantity(3), 6);
    }
    expect(
      localizedMenuName(_names.first, 'en-US'),
      'Stone Pot Bulgogi Bibimbap',
    );
  });

  for (final size in [const Size(390, 844), const Size(1440, 900)]) {
    for (final kind in ['service', 'cancellation', 'staff_meal']) {
      testWidgets('$kind list and open detail change language at $size', (
        tester,
      ) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final locale = ValueNotifier(const Locale('en'));
        addTearDown(locale.dispose);
        final loader = _HistoryLoader(kind);
        await tester.pumpWidget(
          _app(
            locale,
            BmMenuExceptionHistoryScreen(
              stores: const [
                AccessibleStore(id: 'store-1', name: 'BunsikClub Binh Thanh'),
              ],
              initialStartDate: DateTime(2026, 9, 15),
              initialEndDate: DateTime(2026, 9, 15),
              service: loader,
            ),
          ),
        );
        await tester.pumpAndSettle();
        final english = _names.map((n) => n['name_en']).join(', ');
        expect(find.textContaining(english), findsWidgets);
        expect(find.textContaining('돌솥'), findsNothing);
        await tester.tap(find.textContaining(english).first);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('bm_menu_history_detail')), findsOneWidget);
        for (final code in ['vi', 'ko', 'en']) {
          locale.value = Locale(code);
          await tester.pumpAndSettle();
          final expected = _names.map((n) => n['name_$code']).join(', ');
          expect(
            find.descendant(
              of: find.byKey(const Key('bm_menu_history_detail')),
              matching: find.text(expected),
            ),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
        }
        await tester.tap(
          find.byKey(const Key('bm_history_detail_original_order')),
        );
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('bm_original_order_detail')),
          findsOneWidget,
        );
        for (final code in ['vi', 'ko', 'en']) {
          locale.value = Locale(code);
          await tester.pumpAndSettle();
          await tester.scrollUntilVisible(
            find.text(_names.first['name_$code']!),
            180,
            scrollable: find
                .descendant(
                  of: find.byKey(const Key('bm_original_order_detail')),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          expect(find.text(_names.first['name_$code']!), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        expect(
          loader.requests,
          1,
          reason: 'Locale changes must not reload the history snapshot',
        );
      });
    }
  }

  testWidgets('sold-out menu names change in the already open dialog', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1024, 768);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final locale = ValueNotifier(const Locale('en'));
    addTearDown(locale.dispose);
    await tester.pumpWidget(
      _app(
        locale,
        Scaffold(
          body: CashierSoldOutDialog(
            storeId: 'store',
            menuServiceOverride: _MenuService(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final code in ['en', 'vi', 'ko']) {
      locale.value = Locale(code);
      await tester.pumpAndSettle();
      for (final names in _names) {
        expect(find.text(names['name_$code']!), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    }
  });

  testWidgets(
    'menu browser carries translations into the cart across locale changes',
    (tester) async {
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final locale = ValueNotifier(const Locale('en'));
      addTearDown(locale.dispose);
      CartItem? added;
      final cart = ValueNotifier<List<CartItem>>([]);
      addTearDown(cart.dispose);
      await tester.pumpWidget(
        _app(
          locale,
          Scaffold(
            body: ValueListenableBuilder<List<CartItem>>(
              valueListenable: cart,
              builder: (context, items, _) => OrderWorkspace(
                table: const PosTable(
                  id: 'table',
                  storeId: 'store',
                  tableNumber: '1',
                  seatCount: 4,
                  status: 'available',
                ),
                guestCount: 1,
                menuState: MenuState(
                  categories: const AsyncData([
                    {
                      'id': 'main',
                      'name': '메인',
                      'name_ko': '메인',
                      'name_en': 'Main',
                      'name_vi': 'Món chính',
                    },
                  ]),
                  items: AsyncData([
                    {
                      ..._names.first,
                      'id': 'bibimbap',
                      'category_id': 'main',
                      'price': 50000,
                      'is_available': true,
                    },
                  ]),
                  selectedCategoryId: 'main',
                ),
                menuNotifier: null,
                orderState: OrderState(cart: items),
                allowSubmitWithoutCart: false,
                onAddToCart: (item) {
                  added = item;
                  cart.value = [item.copyWith(quantity: 2)];
                },
                onIncrementCartItem: (_) {},
                onDecrementCartItem: (_) {},
                onSetCartItemTakeout: (_, _) {},
                onCancel: () {},
                onCancelOrder: () async {},
                onSendOrder: () async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Main'), findsOneWidget);
      await tester.tap(find.byKey(const Key('menu_first_item_add_card')));
      await tester.pumpAndSettle();
      expect(
        added!.name,
        '돌솥 불고기 비빔밥',
        reason: 'Persist the original menu label',
      );
      for (final code in ['vi', 'ko', 'en']) {
        locale.value = Locale(code);
        await tester.pumpAndSettle();
        expect(find.text(_names.first['name_$code']!), findsWidgets);
        expect(
          cart.value.single.localizedName(code),
          _names.first['name_$code'],
        );
        expect(cart.value.single.quantity, 2);
        expect(tester.takeException(), isNull);
      }
    },
  );
}
