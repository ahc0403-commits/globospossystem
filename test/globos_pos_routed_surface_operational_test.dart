import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/core/services/qr_order_service.dart';
import 'package:globos_pos_system/core/services/restaurant_cutoff_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/admin/admin_screen.dart';
import 'package:globos_pos_system/features/attendance/attendance_kiosk_screen.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/auth/login_screen.dart';
import 'package:globos_pos_system/features/auth/privacy_consent_screen.dart';
import 'package:globos_pos_system/features/cashier/cashier_screen.dart';
import 'package:globos_pos_system/features/kitchen/kitchen_screen.dart';
import 'package:globos_pos_system/features/onboarding/onboarding_screen.dart';
import 'package:globos_pos_system/features/payment/payment_detail_screen.dart';
import 'package:globos_pos_system/features/photo_ops/photo_ops_screen.dart';
import 'package:globos_pos_system/features/print_station/print_station_screen.dart';
import 'package:globos_pos_system/features/qc/qc_check_screen.dart';
import 'package:globos_pos_system/features/qc/qc_review_screen.dart';
import 'package:globos_pos_system/features/qr_order/qr_order_screen.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export_screen.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_models.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_provider.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_screen.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_service.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_screen.dart';
import 'package:globos_pos_system/features/waiter/waiter_screen.dart';
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

class _FixtureSuperAdminNotifier extends SuperAdminNotifier {
  @override
  Future<void> loadAllRestaurants() async {}

  @override
  Future<void> loadBrands() async {}

  @override
  Future<void> loadLegalEntityStructure() async {}

  @override
  Future<void> loadAllReports({String? selectedRestaurantId}) async {}
}

class _FixtureQrOrderService extends QrOrderService {
  @override
  Future<QrOrderMenu> fetchMenu(String token) async => _routeMenu;

  @override
  Future<QrOrderResult> placeOrder({
    required String token,
    required List<QrOrderLine> items,
    required String clientOrderId,
  }) async => const QrOrderResult(
    orderCode: 'ROUTE-1',
    batchNo: 1,
    tableNumber: 'A-12',
    floorLabel: 'Main floor',
    items: [],
  );
}

class _FixtureStoreSetupNotifier extends StoreSetupNotifier {
  _FixtureStoreSetupNotifier(String storeId)
    : super(storeId: storeId, backend: SupabaseStoreSetupBackend()) {
    state = StoreSetupState(
      draft: StoreOpeningDraft(
        storeId: storeId,
        printers: StoreOpeningTemplate.defaultPrinters(),
      ),
      phase: StoreSetupPhase.editing,
      store: const {
        'name': _operationalStoreName,
        'is_active': true,
        'brands': {'name': 'GLOBOS'},
        'tax_entity': {'name': 'GLOBOS Vietnam'},
      },
      workforceReadiness: const {'accounts_ready': true, 'employees_active': 1},
    );
  }

  @override
  Future<void> loadExisting() async {}
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

const _routeMenu = QrOrderMenu(
  storeName: 'GLOBOS Route Fixture',
  tableNumber: 'A-12',
  floorLabel: 'Main floor',
  categories: [QrMenuCategory(id: 'main', name: 'Main')],
  items: [
    QrMenuItem(
      id: 'item',
      categoryId: 'main',
      name: 'Fixture item',
      price: 42000,
    ),
  ],
);

class _ViewportLocale {
  const _ViewportLocale(this.size, this.locale);

  final Size size;
  final Locale locale;
}

const _viewportLocales = <_ViewportLocale>[
  _ViewportLocale(Size(390, 844), Locale('ko')),
  _ViewportLocale(Size(1024, 768), Locale('en')),
  _ViewportLocale(Size(1440, 900), Locale('vi')),
];

typedef _LocalizedLabel = String Function(AppLocalizations l10n, Locale locale);

class _RouteSurface {
  const _RouteSurface({
    required this.location,
    required this.pattern,
    required this.widgetType,
    required this.builder,
    required this.label,
    this.authState = _operationalStoreAuthState,
  });

  final String location;
  final String pattern;
  final Type widgetType;
  final Widget Function() builder;
  final _LocalizedLabel label;
  final PosAuthState authState;
}

final _routeSurfaces = <_RouteSurface>[
  _RouteSurface(
    location: '/qr/fixture-token',
    pattern: '/qr/:token',
    widgetType: QrOrderScreen,
    builder: () => QrOrderScreen(
      token: 'fixture-token',
      service: _FixtureQrOrderService(),
    ),
    label: (_, __) => QrOrderCopy.forLanguage('vi').headerHint,
  ),
  _RouteSurface(
    location: '/login',
    pattern: '/login',
    widgetType: LoginScreen,
    builder: () => const LoginScreen(),
    label: (l10n, _) => l10n.loginStartShift,
    authState: const PosAuthState(),
  ),
  _RouteSurface(
    location: '/privacy-consent',
    pattern: '/privacy-consent',
    widgetType: PrivacyConsentScreen,
    builder: () => const PrivacyConsentScreen(),
    label: (l10n, _) => l10n.privacyConsentTitle,
    authState: const PosAuthState(
      role: 'store_admin',
      privacyConsentRequired: true,
    ),
  ),
  _RouteSurface(
    location: '/onboarding',
    pattern: '/onboarding',
    widgetType: OnboardingScreen,
    builder: () => const OnboardingScreen(),
    label: (l10n, _) => l10n.onboardingSectionTitle,
    authState: const PosAuthState(role: 'super_admin'),
  ),
  _RouteSurface(
    location: '/waiter',
    pattern: '/waiter',
    widgetType: WaiterScreen,
    builder: () => const WaiterScreen(),
    label: (l10n, _) => l10n.waiterScreenTitle,
  ),
  _RouteSurface(
    location: '/kitchen',
    pattern: '/kitchen',
    widgetType: KitchenScreen,
    builder: () => const KitchenScreen(),
    label: (l10n, _) => l10n.kitchenTitle,
  ),
  _RouteSurface(
    location: '/print-station',
    pattern: '/print-station',
    widgetType: PrintStationScreen,
    builder: () => const PrintStationScreen(),
    label: (l10n, _) => l10n.printStationTitle,
  ),
  _RouteSurface(
    location: '/cashier',
    pattern: '/cashier',
    widgetType: CashierScreen,
    builder: () => const CashierScreen(),
    label: (l10n, _) => l10n.cashierTitle,
  ),
  _RouteSurface(
    location: '/attendance-kiosk',
    pattern: '/attendance-kiosk',
    widgetType: AttendanceKioskScreen,
    builder: () => const AttendanceKioskScreen(),
    label: (l10n, _) => l10n.attendanceEmployeeKioskTitle,
  ),
  _RouteSurface(
    location: '/qc-check',
    pattern: '/qc-check',
    widgetType: QcCheckScreen,
    builder: () => const QcCheckScreen(),
    label: (l10n, _) => l10n.qcTitle,
  ),
  _RouteSurface(
    location: '/qc-review',
    pattern: '/qc-review',
    widgetType: QcReviewScreen,
    builder: () => const QcReviewScreen(),
    label: (l10n, _) => l10n.qscReviewTitle,
  ),
  _RouteSurface(
    location: '/photo-ops',
    pattern: '/photo-ops',
    widgetType: PhotoOpsScreen,
    builder: () => const PhotoOpsScreen(),
    label: (l10n, _) => l10n.photoOpsBrandName,
  ),
  _RouteSurface(
    location: '/payments/payment-fixture',
    pattern: '/payments/:paymentId',
    widgetType: PaymentDetailScreen,
    builder: () => PaymentDetailScreen(
      paymentId: 'payment-fixture',
      detailLoader: (_, __) async => null,
    ),
    label: (l10n, _) => l10n.paymentDetailTitle,
  ),
  _RouteSurface(
    location: '/super-admin',
    pattern: '/super-admin',
    widgetType: SuperAdminScreen,
    builder: () => const SuperAdminScreen(),
    label: (l10n, _) => l10n.superAdminStores,
    authState: const PosAuthState(role: 'super_admin'),
  ),
  _RouteSurface(
    location: '/restaurant-sales-export',
    pattern: '/restaurant-sales-export',
    widgetType: RestaurantSalesExportScreen,
    builder: () => const RestaurantSalesExportScreen(),
    label: (l10n, _) => l10n.restaurantSalesExportTitle,
    authState: const PosAuthState(role: 'super_admin'),
  ),
  _RouteSurface(
    location: '/store-setup/7f6c9d22-6d84-4c7f-b923-79c81c4015d1',
    pattern: '/store-setup/:storeId',
    widgetType: StoreSetupScreen,
    builder: () => const StoreSetupScreen(storeId: _operationalStoreId),
    label: (l10n, _) => l10n.storeSetupTitle,
  ),
  _RouteSurface(
    location: '/admin',
    pattern: '/admin',
    widgetType: AdminScreen,
    builder: () => const AdminScreen(),
    label: (l10n, _) => l10n.tables,
  ),
  _RouteSurface(
    location: '/admin/store-fixture',
    pattern: '/admin/:storeId',
    widgetType: AdminScreen,
    builder: () => const AdminScreen(overrideRestaurantId: 'store-fixture'),
    label: (l10n, _) => l10n.tables,
    authState: const PosAuthState(role: 'super_admin'),
  ),
];

Future<GoRouter> _pumpRoute(
  WidgetTester tester, {
  required _RouteSurface surface,
  required _ViewportLocale fixture,
  bool isOnline = true,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = fixture.size;
  final router = GoRouter(
    initialLocation: surface.location,
    routes: [
      GoRoute(path: surface.pattern, builder: (_, __) => surface.builder()),
    ],
  );

  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        authProvider.overrideWith(
          (ref) => _FixtureAuthNotifier(surface.authState),
        ),
        connectivityProvider.overrideWith((ref) => Stream.value(isOnline)),
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
        superAdminProvider.overrideWith((ref) => _FixtureSuperAdminNotifier()),
        storeSetupProvider.overrideWith(
          (ref, storeId) => _FixtureStoreSetupNotifier(storeId),
        ),
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
  await tester.pump(const Duration(milliseconds: 1));
  return router;
}

Finder _touchTargets() => find.byWidgetPredicate(
  (widget) =>
      widget is IconButton ||
      widget is ButtonStyleButton ||
      widget is TextField ||
      (widget is InkWell && widget.onTap != null) ||
      (widget is GestureDetector && widget.onTap != null) ||
      widget is CheckboxListTile ||
      widget is SwitchListTile ||
      widget is RadioListTile<Object?> ||
      widget is DropdownButton<Object?> ||
      widget is SegmentedButton<Object?> ||
      (widget is Semantics && widget.properties.button == true),
);

bool _isImplementationDetailOfTouchTarget(Element element) {
  final widget = element.widget;
  final isGestureImplementation =
      widget is InkWell || widget is GestureDetector;
  final isSemanticsImplementation =
      widget is Semantics && widget.properties.button == true;
  if (!isGestureImplementation && !isSemanticsImplementation) return false;

  var nested = false;
  element.visitAncestorElements((ancestor) {
    final parent = ancestor.widget;
    final isParentTouchTarget =
        parent is ButtonStyleButton ||
        parent is IconButton ||
        parent is TextField ||
        parent is TextFieldTapRegion ||
        parent is CheckboxListTile ||
        parent is SwitchListTile ||
        parent is RadioListTile<Object?> ||
        parent is DropdownButton<Object?> ||
        parent is SegmentedButton<Object?> ||
        (parent is Semantics && parent.properties.button == true);
    if (isParentTouchTarget) {
      nested = true;
      return false;
    }
    return true;
  });
  return nested;
}

void _expectEveryVisibleTouchTargetIsSized(
  WidgetTester tester,
  _RouteSurface surface,
) {
  final targets = _touchTargets();
  for (final element in targets.evaluate()) {
    if (_isImplementationDetailOfTouchTarget(element)) continue;
    final renderObject = element.renderObject;
    if (renderObject is! RenderBox || !renderObject.hasSize) continue;
    final target = find.byElementPredicate((candidate) => candidate == element);
    final touchSize = tester.getSize(target);
    final semanticsLabel = element.widget is Semantics
        ? (element.widget as Semantics).properties.label
        : null;
    final ancestors = <String>[];
    element.visitAncestorElements((ancestor) {
      if (ancestors.length >= 6) return false;
      ancestors.add(ancestor.widget.runtimeType.toString());
      return true;
    });
    final identity = <String>[
      element.widget.runtimeType.toString(),
      if (element.widget.key != null) 'key=${element.widget.key}',
      if (semanticsLabel != null) 'label=$semanticsLabel',
      'ancestors=${ancestors.join('>')}',
    ].join(' ');
    expect(
      touchSize.width,
      greaterThanOrEqualTo(48),
      reason:
          '${surface.location} has $identity '
          'with ${touchSize.width}dp width',
    );
    expect(
      touchSize.height,
      greaterThanOrEqualTo(48),
      reason:
          '${surface.location} has $identity '
          'with ${touchSize.height}dp height',
    );
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

  tearDown(() {
    FocusManager.instance.primaryFocus?.unfocus();
  });

  testWidgets(
    'all eighteen approved routes render localized focusable touch surfaces',
    (tester) async {
      final semantics = tester.ensureSemantics();
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      expect(_routeSurfaces, hasLength(18));

      GoRouter? previousRouter;
      for (final fixture in _viewportLocales) {
        for (final surface in _routeSurfaces) {
          final router = await _pumpRoute(
            tester,
            surface: surface,
            fixture: fixture,
          );
          previousRouter?.dispose();
          previousRouter = router;

          final root = find.byType(surface.widgetType);
          expect(root, findsOneWidget, reason: surface.location);
          final l10n = AppLocalizations.of(tester.element(root))!;
          final localizedLabel = surface.label(l10n, fixture.locale);
          expect(
            find.text(localizedLabel),
            findsWidgets,
            reason: '${surface.location} did not render localized content',
          );
          expect(find.byType(Semantics), findsWidgets);

          _expectEveryVisibleTouchTargetIsSized(tester, surface);

          await tester.sendKeyEvent(LogicalKeyboardKey.tab);
          await tester.pump();
          expect(
            FocusManager.instance.primaryFocus,
            isNotNull,
            reason: '${surface.location} has no keyboard focus path',
          );
          expect(
            tester.takeException(),
            isNull,
            reason:
                '${surface.location} overflowed at ${fixture.size} '
                '${fixture.locale} with 200% text',
          );
        }
      }
      previousRouter?.dispose();
      semantics.dispose();
    },
  );

  testWidgets(
    'all eighteen routes preserve every touch target in offline state',
    (tester) async {
      final semantics = tester.ensureSemantics();
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      GoRouter? previousRouter;
      for (final fixture in _viewportLocales) {
        for (final surface in _routeSurfaces) {
          final router = await _pumpRoute(
            tester,
            surface: surface,
            fixture: fixture,
            isOnline: false,
          );
          previousRouter?.dispose();
          previousRouter = router;

          expect(
            find.byType(surface.widgetType),
            findsOneWidget,
            reason: '${surface.location} did not survive offline state',
          );
          _expectEveryVisibleTouchTargetIsSized(tester, surface);
          expect(
            tester.takeException(),
            isNull,
            reason:
                '${surface.location} failed offline at ${fixture.size} '
                '${fixture.locale}',
          );
        }
      }
      previousRouter?.dispose();
      semantics.dispose();
    },
  );
}
