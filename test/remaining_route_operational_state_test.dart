import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/core/ui/app_primitives.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/admin/providers/printer_destinations_provider.dart';
import 'package:globos_pos_system/features/attendance/attendance_kiosk_screen.dart';
import 'package:globos_pos_system/features/attendance/attendance_kiosk_provider.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/auth/login_screen.dart';
import 'package:globos_pos_system/features/auth/privacy_consent_screen.dart';
import 'package:globos_pos_system/features/kitchen/kitchen_provider.dart';
import 'package:globos_pos_system/features/onboarding/onboarding_provider.dart';
import 'package:globos_pos_system/features/onboarding/onboarding_screen.dart';
import 'package:globos_pos_system/features/payment/payment_detail_screen.dart';
import 'package:globos_pos_system/features/photo_ops/photo_ops_provider.dart';
import 'package:globos_pos_system/features/photo_ops/photo_ops_screen.dart';
import 'package:globos_pos_system/features/photo_ops/photo_ops_service.dart';
import 'package:globos_pos_system/features/print_station/print_station_screen.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export.dart';
import 'package:globos_pos_system/features/restaurant_sales_export/restaurant_sales_export_screen.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_models.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_provider.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_screen.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_service.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '7f6c9d22-6d84-4c7f-b923-79c81c4015d1';

const _storeAuth = PosAuthState(
  role: 'store_admin',
  storeId: _storeId,
  primaryStoreId: _storeId,
  accessibleStores: [AccessibleStore(id: _storeId, name: 'GLOBOS Nguyễn Huệ')],
);

class _AuthNotifier extends AuthNotifier {
  _AuthNotifier(PosAuthState initialState) : super() {
    state = initialState;
  }

  @override
  Future<void> logout() async {}
}

class _OnboardingNotifier extends OnboardingNotifier {
  _OnboardingNotifier(super.ref, OnboardingState initialState) {
    state = initialState;
  }

  @override
  Future<void> finish() async {}
}

class _AttendanceNotifier extends AttendanceKioskNotifier {
  _AttendanceNotifier({this.completion});

  final Completer<bool>? completion;

  @override
  Future<bool> recordAttendance({
    required String employeeNumber,
    required String storeId,
    required String type,
  }) => completion?.future ?? Future<bool>.value(true);
}

class _PrinterDestinationsNotifier extends PrinterDestinationsNotifier {
  _PrinterDestinationsNotifier(PrinterDestinationsState initialState)
    : super(_storeId, autoLoad: false) {
    state = initialState;
  }
}

class _PhotoOpsNotifier extends PhotoOpsNotifier {
  _PhotoOpsNotifier(super.ref, PhotoOpsState initialState) {
    state = initialState;
  }

  @override
  Future<void> load() async {}
}

class _StoreSetupNotifier extends StoreSetupNotifier {
  _StoreSetupNotifier(StoreSetupState initialState)
    : super(storeId: _storeId, backend: SupabaseStoreSetupBackend()) {
    state = initialState;
  }

  @override
  Future<void> loadExisting() async {}
}

StoreOpeningDraft _storeSetupDraft() => StoreOpeningDraft(
  storeId: _storeId,
  printers: StoreOpeningTemplate.defaultPrinters(),
);

Future<void> _pump(
  WidgetTester tester, {
  required Widget child,
  PosAuthState authState = _storeAuth,
  List<Override> overrides = const [],
  Size physicalSize = const Size(1280, 900),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = physicalSize;
  final router = GoRouter(
    initialLocation: '/',
    routes: [GoRoute(path: '/', builder: (_, __) => child)],
  );
  addTearDown(router.dispose);
  await tester.pumpWidget(
    ProviderScope(
      key: UniqueKey(),
      overrides: [
        authProvider.overrideWith((ref) => _AuthNotifier(authState)),
        ...overrides,
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
  await tester.pump();
}

void _expectButtonDisabled(WidgetTester tester, Finder finder) {
  final button = tester.widget<ButtonStyleButton>(finder);
  expect(button.onPressed, isNull);
  expect(tester.getSize(finder).height, greaterThanOrEqualTo(48));
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

  testWidgets('Login executes explicit error and disabled loading states', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      child: const LoginScreen(),
      authState: const PosAuthState(
        isLoading: true,
        errorMessage: authErrorGenericLogin,
      ),
    );

    expect(find.byKey(const Key('auth_error_text')), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    _expectButtonDisabled(tester, find.byKey(const Key('login_submit_button')));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Privacy consent executes error, submitting, disabled, and selected states',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(
        tester,
        child: const PrivacyConsentScreen(),
        authState: const PosAuthState(
          role: 'store_admin',
          privacyConsentRequired: true,
          isPrivacyConsentSubmitting: true,
          errorMessage: authErrorPrivacyConsentFailed,
        ),
      );

      expect(
        find.byKey(const Key('privacy_consent_error_text')),
        findsOneWidget,
      );
      final disabledCheckbox = tester.widget<CheckboxListTile>(
        find.byKey(const Key('privacy_consent_checkbox')),
      );
      expect(disabledCheckbox.onChanged, isNull);
      _expectButtonDisabled(tester, find.byKey(privacyConsentAcceptButtonKey));

      await _pump(
        tester,
        child: const PrivacyConsentScreen(),
        authState: const PosAuthState(
          role: 'store_admin',
          privacyConsentRequired: true,
        ),
      );
      final checkbox = find.byKey(const Key('privacy_consent_checkbox'));
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pump();
      final selectedCheckbox = tester.widget<CheckboxListTile>(
        find.byKey(const Key('privacy_consent_checkbox')),
      );
      expect(selectedCheckbox.value, isTrue);
      expect(
        tester
            .widget<ButtonStyleButton>(
              find.byKey(privacyConsentAcceptButtonKey),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Onboarding executes loading, error, profile, and done states', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      child: const OnboardingScreen(),
      authState: const PosAuthState(role: 'super_admin'),
      overrides: [
        onboardingProvider.overrideWith(
          (ref) => _OnboardingNotifier(
            ref,
            const OnboardingState(
              isLoading: true,
              error: onboardingOnlySuperAdminErrorCode,
            ),
          ),
        ),
      ],
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(
      tester
          .widgetList<ButtonStyleButton>(find.byType(FilledButton))
          .every((button) => button.onPressed == null),
      isTrue,
    );

    await _pump(
      tester,
      child: const OnboardingScreen(),
      authState: const PosAuthState(role: 'super_admin'),
      overrides: [
        onboardingProvider.overrideWith(
          (ref) => _OnboardingNotifier(
            ref,
            const OnboardingState(
              step: 1,
              createdStoreId: _storeId,
              createdStoreName: 'GLOBOS Nguyễn Huệ',
            ),
          ),
        ),
      ],
    );
    expect(find.byType(TextField), findsOneWidget);

    await _pump(
      tester,
      child: const OnboardingScreen(),
      authState: const PosAuthState(role: 'super_admin'),
      overrides: [
        onboardingProvider.overrideWith(
          (ref) => _OnboardingNotifier(
            ref,
            const OnboardingState(
              step: 2,
              createdStoreId: _storeId,
              createdStoreName: 'GLOBOS Nguyễn Huệ',
            ),
          ),
        ),
      ],
    );
    expect(find.text('GLOBOS Nguyễn Huệ'), findsOneWidget);
    expect(find.byIcon(Icons.check_circle), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Print Station executes unsupported, queue error, and empty states',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await _pump(
        tester,
        child: const PrintStationScreen(isSupportedOverride: false),
        overrides: [
          connectivityProvider.overrideWith((ref) => Stream.value(true)),
        ],
      );
      expect(find.byKey(const Key('print_station_start')), findsNothing);
      expect(
        tester.takeException(),
        isNull,
        reason: 'unsupported Print Station state overflowed',
      );

      await _pump(
        tester,
        child: const PrintStationScreen(isSupportedOverride: true),
        overrides: [
          connectivityProvider.overrideWith((ref) => Stream.value(false)),
          printerDestinationsProvider.overrideWith(
            (ref, storeId) => _PrinterDestinationsNotifier(
              const PrinterDestinationsState(
                error: PrinterDestinationErrorCodes.loadFailed,
              ),
            ),
          ),
          printStationJobsProvider.overrideWith(
            (ref, storeId) =>
                Future<List<FailedPrintJob>>.error(StateError('queue offline')),
          ),
          failedPrintJobsProvider.overrideWith(
            (ref, storeId) async => const <FailedPrintJob>[],
          ),
        ],
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('print_station_job_feed')), findsOneWidget);
      final printStationL10n = AppLocalizations.of(
        tester.element(find.byType(PrintStationScreen)),
      )!;
      expect(find.text(printStationL10n.storeSetupErrorTestPoll), findsWidgets);
      expect(
        find.byKey(const Key('print_station_failed_jobs')),
        findsOneWidget,
      );
      expect(find.byKey(const Key('print_station_start')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Attendance kiosk executes submitting and offline-disabled states',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final attendanceResult = Completer<bool>();
      await _pump(
        tester,
        child: const AttendanceKioskScreen(),
        overrides: [
          connectivityProvider.overrideWith((ref) => Stream.value(true)),
          attendanceKioskProvider.overrideWith(
            (ref) => _AttendanceNotifier(completion: attendanceResult),
          ),
        ],
      );
      await tester.enterText(
        find.byKey(const Key('attendance_employee_number_field')),
        'NV-001',
      );
      await tester.tap(find.byKey(const Key('attendance_employee_clock_in')));
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      attendanceResult.complete(true);
      await tester.pump();

      await _pump(
        tester,
        child: const AttendanceKioskScreen(),
        overrides: [
          connectivityProvider.overrideWith((ref) => Stream.value(false)),
          attendanceKioskProvider.overrideWith((ref) => _AttendanceNotifier()),
        ],
      );
      await tester.pump();
      final clockIn = find.byKey(const Key('attendance_employee_clock_in'));
      final clockOut = find.byKey(const Key('attendance_employee_clock_out'));
      _expectButtonDisabled(tester, clockIn);
      _expectButtonDisabled(tester, clockOut);
      expect(tester.getSize(clockIn).height, greaterThanOrEqualTo(72));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('Photo Ops executes loading, error, and populated queue states', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      child: const PhotoOpsScreen(),
      physicalSize: const Size(800, 1000),
      overrides: [
        photoOpsProvider.overrideWith(
          (ref) => _PhotoOpsNotifier(ref, const PhotoOpsState(isLoading: true)),
        ),
      ],
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    await _pump(
      tester,
      child: const PhotoOpsScreen(),
      physicalSize: const Size(800, 900),
      overrides: [
        photoOpsProvider.overrideWith(
          (ref) => _PhotoOpsNotifier(
            ref,
            const PhotoOpsState(error: 'Photo queue unavailable'),
          ),
        ),
      ],
    );
    expect(find.text('Photo queue unavailable'), findsOneWidget);

    final data = PhotoOpsDashboardData(
      kpi: const PhotoOpsKpi(
        allAttendanceEvents: 4,
        activeAttendanceEvents: 2,
        allInventoryAlerts: 2,
        activeInventoryAlerts: 1,
        activePayrollEstimate: 1250000,
        activeStoreSales: 4200000,
        networkSales: 7800000,
        activeStoreTransactions: 36,
      ),
      recentAttendance: [
        PhotoOpsAttendanceRow(
          employeeName: 'Nguyễn Minh Anh',
          type: 'clock_in',
          loggedAt: DateTime(2026, 7, 18, 8),
        ),
      ],
      inventoryAlerts: const [
        PhotoOpsInventoryRow(
          ingredientId: 'ingredient-beef',
          itemName: 'Thịt bò',
          currentStock: 1250,
          unit: 'g',
          reorderPoint: 1500,
          needsReorder: true,
          supplierName: 'Fresh Food Saigon',
        ),
      ],
      payrollPreview: const [
        PhotoOpsPayrollRow(
          employeeName: 'Nguyễn Minh Anh',
          totalHours: 42,
          totalAmount: 2100000,
          shiftCount: 6,
        ),
      ],
      salesSummary: [
        PhotoOpsSalesRow(
          storeId: _storeId,
          storeName: 'GLOBOS Nguyễn Huệ',
          saleDate: DateTime(2026, 7, 18),
          grossSales: 4200000,
          totalTransactions: 36,
          serviceAmount: 120000,
          activeMachines: 2,
        ),
      ],
      salesWarningCode: 'PHOTO_SALES_PULL_PARTIAL',
      salesWarningDetail: 'One terminal is delayed',
    );
    await _pump(
      tester,
      child: const PhotoOpsScreen(),
      physicalSize: const Size(800, 1400),
      overrides: [
        photoOpsProvider.overrideWith(
          (ref) => _PhotoOpsNotifier(ref, PhotoOpsState(data: data)),
        ),
      ],
    );
    expect(find.text('Nguyễn Minh Anh'), findsWidgets);
    expect(find.text('Thịt bò'), findsOneWidget);
    expect(find.byKey(const Key('photo_ops_section_1')), findsOneWidget);
    await tester.tap(find.byKey(const Key('photo_ops_section_1')));
    await tester.pump();
    final adjustInventory = find.byKey(
      const ValueKey('photo_ops_inventory_adjust_ingredient-beef'),
    );
    await tester.ensureVisible(adjustInventory);
    await tester.tap(adjustInventory);
    await tester.pumpAndSettle();
    const adjustmentDialog = Key('photo_ops_inventory_adjustment_dialog');
    expect(find.byKey(adjustmentDialog), findsOneWidget);
    await tester.tap(
      find.byKey(const Key('photo_ops_inventory_adjustment_save')),
    );
    await tester.pump();
    expect(find.byKey(adjustmentDialog), findsOneWidget);
    Navigator.of(tester.element(find.byKey(adjustmentDialog))).pop();
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'Payment detail executes loading, error, empty, and data states',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pending = Completer<Map<String, dynamic>?>();
      await _pump(
        tester,
        child: PaymentDetailScreen(
          paymentId: 'payment-loading',
          detailLoader: (_, __) => pending.future,
        ),
        authState: const PosAuthState(),
      );
      expect(find.byType(AppLoadingView), findsOneWidget);

      await _pump(
        tester,
        child: PaymentDetailScreen(
          paymentId: 'payment-error',
          detailLoader: (_, __) => Future.error(StateError('detail offline')),
        ),
        authState: const PosAuthState(),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppErrorState), findsOneWidget);
      expect(find.textContaining('detail offline'), findsOneWidget);

      await _pump(
        tester,
        child: PaymentDetailScreen(
          paymentId: 'payment-empty',
          detailLoader: (_, __) async => null,
        ),
        authState: const PosAuthState(),
      );
      await tester.pumpAndSettle();
      expect(find.byType(AppEmptyState), findsOneWidget);

      await _pump(
        tester,
        child: PaymentDetailScreen(
          paymentId: 'payment-data',
          detailLoader: (_, __) async => const {
            'payment': {
              'id': 'payment-data',
              'status': 'completed',
              'amount': 48000,
              'method': 'cash',
              'is_revenue': true,
            },
            'order': {
              'id': 'order-data',
              'tables': {'table_number': 'A-12'},
              'order_items': [],
            },
            'adjustments': [],
          },
        ),
        authState: const PosAuthState(),
      );
      await tester.pumpAndSettle();
      expect(find.textContaining('48.000 VND'), findsWidgets);
      expect(find.textContaining('A-12'), findsWidgets);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Sales export executes disabled loading and explicit error states',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final pending = Completer<RestaurantSalesExport>();
      await _pump(
        tester,
        child: RestaurantSalesExportScreen(loader: (_) => pending.future),
      );
      final exportAction = find.byKey(
        const Key('restaurant_sales_export_button'),
      );
      await tester.tap(exportAction);
      await tester.pump();
      _expectButtonDisabled(tester, exportAction);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await _pump(
        tester,
        child: RestaurantSalesExportScreen(
          loader: (_) => Future.error(
            const FormatException('RESTAURANT_EXPORT_NOT_READY'),
          ),
        ),
      );
      await tester.tap(find.byKey(const Key('restaurant_sales_export_button')));
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('restaurant_sales_export_status')),
        findsOneWidget,
      );
      expect(
        tester
            .widget<ButtonStyleButton>(
              find.byKey(const Key('restaurant_sales_export_button')),
            )
            .onPressed,
        isNotNull,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'Store setup executes loading, error, disabled, and selected states',
    (tester) async {
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await _pump(
        tester,
        child: const StoreSetupScreen(storeId: _storeId),
        overrides: [
          storeSetupProvider.overrideWith(
            (ref, storeId) =>
                _StoreSetupNotifier(StoreSetupState(draft: _storeSetupDraft())),
          ),
        ],
      );
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await _pump(
        tester,
        child: const StoreSetupScreen(storeId: _storeId),
        overrides: [
          storeSetupProvider.overrideWith(
            (ref, storeId) => _StoreSetupNotifier(
              StoreSetupState(
                draft: _storeSetupDraft(),
                phase: StoreSetupPhase.blocked,
                errorCode: 'STORE_SETUP_LOAD_FAILED',
              ),
            ),
          ),
        ],
      );
      expect(find.byType(MaterialBanner), findsOneWidget);
      expect(
        find.byKey(const Key('store_setup_six_step_wizard')),
        findsOneWidget,
      );

      await _pump(
        tester,
        child: const StoreSetupScreen(storeId: _storeId),
        overrides: [
          storeSetupProvider.overrideWith(
            (ref, storeId) => _StoreSetupNotifier(
              StoreSetupState(
                draft: _storeSetupDraft(),
                phase: StoreSetupPhase.validating,
                store: const {'name': 'GLOBOS Nguyễn Huệ', 'is_active': true},
              ),
            ),
          ),
        ],
      );
      _expectButtonDisabled(
        tester,
        find.byKey(const Key('store_setup_next_0')),
      );
      expect(tester.takeException(), isNull);
    },
  );
}
