import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/features/admin/admin_screen.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/inventory_purchase/inventory_purchase_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FixtureAuthNotifier extends AuthNotifier {
  _FixtureAuthNotifier(PosAuthState initialState) : super() {
    state = initialState;
  }

  @override
  Future<void> logout() async {}

  @override
  Future<void> setActiveStore(String storeId) async {}
}

const _operationalStoreId = '7f6c9d22-6d84-4c7f-b923-79c81c4015d1';
const _operationalStoreName = 'GLOBOS Nguyễn Huệ';

const _operationalStoreAuthState = PosAuthState(
  role: 'store_admin',
  storeId: _operationalStoreId,
  primaryStoreId: _operationalStoreId,
  accessibleStores: [
    AccessibleStore(id: _operationalStoreId, name: _operationalStoreName),
  ],
);

const _photoMasterAuthState = PosAuthState(
  role: 'photo_objet_master',
  storeId: _operationalStoreId,
  primaryStoreId: _operationalStoreId,
  accessibleStores: [
    AccessibleStore(id: _operationalStoreId, name: 'PHOTO OBJET BIEN HOA'),
  ],
);

class _ViewportLocale {
  const _ViewportLocale(this.size, this.locale);

  final Size size;
  final Locale locale;
}

typedef _LocalizedLabel = String Function(AppLocalizations l10n);

const _viewportLocales = <_ViewportLocale>[
  _ViewportLocale(Size(390, 844), Locale('ko')),
  _ViewportLocale(Size(1024, 768), Locale('en')),
  _ViewportLocale(Size(1440, 900), Locale('vi')),
];

final _inventoryTitles = <_LocalizedLabel>[
  (l10n) => l10n.inventoryPurchaseDashboardTitle,
  (l10n) => l10n.inventoryPurchaseStockStatusTitle,
  (l10n) => l10n.inventoryPurchaseManagementTitle,
  (l10n) => l10n.inventoryPurchaseHistoryTitle,
  (l10n) => l10n.inventoryPurchaseSupplierManagementTitle,
  (l10n) => l10n.inventoryPurchaseProductManagementTitle,
  (l10n) => l10n.inventoryPurchaseRecipeManagementTitle,
  (l10n) => l10n.inventoryPurchaseConsumptionTrendTitle,
  (l10n) => l10n.inventoryPurchaseCostAnalysisTitle,
  (l10n) => l10n.inventoryPurchaseStockAuditTitle,
  (l10n) => l10n.inventoryPurchaseNewMenuTitle,
];

final _adminLabels = <_LocalizedLabel>[
  (l10n) => l10n.tables,
  (l10n) => l10n.menu,
  (l10n) => l10n.staff,
  (l10n) => l10n.reports,
  (l10n) => l10n.attendance,
  (l10n) => l10n.inventory,
  (l10n) => l10n.navQuality,
  (l10n) => l10n.settings,
  (l10n) => l10n.deliberrySettlement,
  (l10n) => l10n.eInvoice,
];

const _adminRootKeys = <Key>[
  Key('admin_tables_root'),
  Key('admin_menu_root'),
  Key('staff_root'),
  Key('reports_root'),
  Key('attendance_root'),
  Key('inventory_root'),
  Key('qc_root'),
  Key('settings_root'),
  Key('delivery_settlement_root'),
  Key('einvoice_root'),
];

const _adminNavKeys = <Key>[
  Key('nav_tables'),
  Key('nav_menu'),
  Key('nav_staff'),
  Key('nav_reports'),
  Key('nav_attendance'),
  Key('nav_inventory'),
  Key('nav_qc'),
  Key('nav_settings'),
  Key('nav_delivery_settlement'),
  Key('nav_einvoice'),
];

Future<void> _pumpInventory(
  WidgetTester tester, {
  required _ViewportLocale fixture,
  required int sectionIndex,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = fixture.size;

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith(
          (ref) => _FixtureAuthNotifier(_operationalStoreAuthState),
        ),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(),
        locale: fixture.locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: InventoryPurchaseScreen(
            key: ValueKey('inventory-$sectionIndex-${fixture.locale}'),
            initialSectionIndex: sectionIndex,
            autoLoad: false,
          ),
        ),
      ),
    ),
  );
  await tester.pump();
}

Future<GoRouter> _pumpAdmin(
  WidgetTester tester, {
  required _ViewportLocale fixture,
  required int tabIndex,
  PosAuthState authState = _operationalStoreAuthState,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = fixture.size;
  final router = GoRouter(
    initialLocation: '/admin',
    routes: [
      GoRoute(
        path: '/admin',
        builder: (context, state) => AdminScreen(
          key: ValueKey('admin-$tabIndex-${fixture.locale}'),
          initialTabIndex: tabIndex,
        ),
      ),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _FixtureAuthNotifier(authState)),
        connectivityProvider.overrideWith((ref) => Stream.value(true)),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(),
        locale: fixture.locale,
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        routerConfig: router,
      ),
    ),
  );
  await tester.pump();
  return router;
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

  tearDown(() {
    FocusManager.instance.primaryFocus?.unfocus();
  });

  testWidgets('Photo admin hides restaurant table and menu setup', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await _pumpAdmin(
      tester,
      fixture: _viewportLocales.last,
      tabIndex: 0,
      authState: _photoMasterAuthState,
    );

    expect(find.byKey(const Key('nav_tables')), findsNothing);
    expect(find.byKey(const Key('nav_menu')), findsNothing);
    expect(find.byKey(const Key('nav_staff')), findsOneWidget);
  });

  testWidgets(
    'all eleven Inventory steps expose real localized selected workspaces',
    (tester) async {
      final semantics = tester.ensureSemantics();
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      expect(_inventoryTitles, hasLength(11));
      for (final fixture in _viewportLocales) {
        for (var index = 0; index < _inventoryTitles.length; index++) {
          await _pumpInventory(tester, fixture: fixture, sectionIndex: index);

          final root = find.byKey(const Key('inventory_root'));
          final selectedItem = find.byKey(Key('inventory_section_$index'));
          final l10n = AppLocalizations.of(tester.element(root))!;

          expect(root, findsOneWidget);
          expect(find.text(_inventoryTitles[index](l10n)), findsWidgets);
          await tester.scrollUntilVisible(
            selectedItem,
            180,
            scrollable: find.descendant(
              of: find.byKey(const Key('inventory_section_rail')),
              matching: find.byType(Scrollable),
            ),
          );
          expect(selectedItem, findsOneWidget);
          expect(
            tester.getSemantics(selectedItem).flagsCollection.isSelected,
            Tristate.isTrue,
          );
          final touchSize = tester.getSize(selectedItem);
          expect(touchSize.width, greaterThanOrEqualTo(48));
          expect(touchSize.height, greaterThanOrEqualTo(48));
          final exception = tester.takeException();
          expect(
            exception,
            isNull,
            reason:
                'Inventory step $index overflowed at ${fixture.size} '
                '${fixture.locale} with 200% text',
          );
        }

        await _pumpInventory(tester, fixture: fixture, sectionIndex: 0);
        await tester.tap(find.byKey(const Key('inventory_section_1')));
        await tester.pump();
        expect(
          tester
              .getSemantics(find.byKey(const Key('inventory_section_1')))
              .flagsCollection
              .isSelected,
          Tristate.isTrue,
        );

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus, isNotNull);
        expect(tester.takeException(), isNull);
      }
      semantics.dispose();
    },
  );

  testWidgets(
    'all ten Admin tabs render localized selected operational workspaces',
    (tester) async {
      final semantics = tester.ensureSemantics();
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      expect(_adminLabels, hasLength(10));
      expect(_adminRootKeys, hasLength(10));
      for (final fixture in _viewportLocales) {
        GoRouter? previousRouter;
        for (var index = 0; index < _adminLabels.length; index++) {
          final router = await _pumpAdmin(
            tester,
            fixture: fixture,
            tabIndex: index,
          );
          previousRouter?.dispose();
          previousRouter = router;

          final adminRoot = find.byKey(const Key('admin_root'));
          final selectedRoot = find.byKey(_adminRootKeys[index]);
          final l10n = AppLocalizations.of(tester.element(adminRoot))!;

          expect(adminRoot, findsOneWidget);
          expect(selectedRoot, findsOneWidget);
          expect(find.text(_adminLabels[index](l10n)), findsWidgets);

          if (fixture.size.width < 560) {
            final selector = find.byKey(
              const Key('toast_compact_section_semantics'),
            );
            expect(
              tester.getSemantics(selector).flagsCollection.isSelected,
              Tristate.isTrue,
            );
            final touchSize = tester.getSize(selector);
            expect(touchSize.width, greaterThanOrEqualTo(48));
            expect(touchSize.height, greaterThanOrEqualTo(48));
          } else {
            final selectedNav = find.byKey(_adminNavKeys[index]);
            await tester.scrollUntilVisible(
              selectedNav,
              72,
              scrollable: find.descendant(
                of: find.byKey(const Key('toast_sidebar_rail_list')),
                matching: find.byType(Scrollable),
              ),
            );
            expect(
              tester.getSemantics(selectedNav).flagsCollection.isSelected,
              Tristate.isTrue,
            );
            final touchSize = tester.getSize(selectedNav);
            expect(touchSize.width, greaterThanOrEqualTo(48));
            expect(touchSize.height, greaterThanOrEqualTo(48));
          }
          expect(
            tester.takeException(),
            isNull,
            reason:
                'Admin tab $index overflowed at ${fixture.size} '
                '${fixture.locale} with 200% text',
          );
        }

        final router = await _pumpAdmin(tester, fixture: fixture, tabIndex: 0);
        previousRouter?.dispose();
        previousRouter = router;
        if (fixture.size.width < 560) {
          await tester.tap(
            find.byKey(const Key('toast_compact_section_selector')),
          );
          await tester.pumpAndSettle();
          final l10n = AppLocalizations.of(
            tester.element(find.byKey(const Key('admin_root'))),
          )!;
          await tester.tap(find.text(l10n.menu).last);
        } else {
          await tester.tap(find.byKey(const Key('nav_menu')));
        }
        await tester.pump();
        expect(find.byKey(const Key('admin_menu_root')), findsOneWidget);

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pump();
        expect(FocusManager.instance.primaryFocus, isNotNull);
        expect(tester.takeException(), isNull);
        previousRouter.dispose();
      }
      semantics.dispose();
    },
  );
}
