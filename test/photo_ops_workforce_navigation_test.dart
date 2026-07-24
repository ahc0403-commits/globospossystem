import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/core/ui/toast/toast.dart';
import 'package:globos_pos_system/core/services/attendance_service.dart';
import 'package:globos_pos_system/core/services/payroll_service.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/photo_ops/photo_ops_provider.dart';
import 'package:globos_pos_system/features/photo_ops/photo_ops_screen.dart';
import 'package:globos_pos_system/features/photo_ops/photo_ops_service.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '7f6c9d22-6d84-4c7f-b923-79c81c4015d1';

class _AuthNotifier extends AuthNotifier {
  _AuthNotifier(String role) : super() {
    state = PosAuthState(
      role: role,
      storeId: _storeId,
      primaryStoreId: _storeId,
      accessibleStores: const [
        AccessibleStore(
          id: _storeId,
          name: 'PHOTO OBJET DI AN',
          brandName: 'PHOTO OBJET',
        ),
      ],
    );
  }

  @override
  Future<void> logout() async {}
}

class _PhotoOpsNotifier extends PhotoOpsNotifier {
  _PhotoOpsNotifier(super.ref, {PhotoOpsState? initialState}) {
    state = initialState ?? const PhotoOpsState(isLoading: true);
  }

  @override
  Future<void> load() async {}
}

class _AttendanceService extends AttendanceService {
  String? uploadedEmployeeNumber;
  String? recordedPhotoUrl;

  @override
  Future<String?> uploadEmployeeAttendancePhoto({
    required String storeId,
    required String employeeNumber,
    required XFile originalFile,
    required String type,
  }) async {
    uploadedEmployeeNumber = employeeNumber;
    return 'https://example.test/attendance.jpg';
  }

  @override
  Future<Map<String, dynamic>> recordEmployeeAttendance({
    required String storeId,
    required String employeeNumber,
    required String type,
    String? photoUrl,
  }) async {
    recordedPhotoUrl = photoUrl;
    return const {'id': 'attendance'};
  }
}

class _PayrollService extends PayrollService {
  bool calculated = false;
  bool exported = false;

  @override
  Future<List<StaffPayroll>> calculatePayroll({
    required String storeId,
    required DateTime periodStart,
    required DateTime periodEnd,
  }) async {
    calculated = true;
    return const [];
  }

  @override
  Future<List<int>> exportToExcel({
    required List<StaffPayroll> payrolls,
    required DateTime periodStart,
    required DateTime periodEnd,
  }) async {
    exported = true;
    return [1, 2, 3];
  }
}

PhotoOpsDashboardData _dashboardData() => PhotoOpsDashboardData(
  kpi: const PhotoOpsKpi(
    allAttendanceEvents: 0,
    activeAttendanceEvents: 0,
    allInventoryAlerts: 0,
    activeInventoryAlerts: 0,
    activePayrollEstimate: 0,
  ),
  recentAttendance: const [],
  inventoryAlerts: const [],
  payrollPreview: const [],
);

Future<GoRouter> _pumpPhotoOps(
  WidgetTester tester,
  String role, {
  PhotoOpsState? photoOpsState,
  Size physicalSize = const Size(1440, 900),
  PhotoOpsScreen screen = const PhotoOpsScreen(),
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = physicalSize;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final router = GoRouter(
    initialLocation: '/photo-ops',
    routes: [
      GoRoute(
        path: '/photo-ops',
        builder: (_, __) => Scaffold(body: screen),
      ),
      GoRoute(
        path: '/admin',
        builder: (_, __) => const Scaffold(
          body: Center(
            child: Text(
              'employee-management',
              key: Key('employee_management_destination'),
            ),
          ),
        ),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _AuthNotifier(role)),
        photoOpsProvider.overrideWith(
          (ref) => _PhotoOpsNotifier(ref, initialState: photoOpsState),
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

  testWidgets('Photo master can open the brand manager workspace', (
    tester,
  ) async {
    await _pumpPhotoOps(tester, 'photo_objet_master');

    expect(find.text('PHOTO OBJET DI AN'), findsWidgets);
    expect(find.text('PHOTO OBJET / PHOTO OBJET DI AN'), findsNothing);
    expect(find.byKey(const Key('photo_ops_open_brand_manager')), findsOne);

    await tester.tap(find.byKey(const Key('photo_ops_open_brand_manager')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('employee_management_destination')), findsOne);
  });

  testWidgets('Photo store operator home remains restricted', (tester) async {
    final router = await _pumpPhotoOps(tester, 'photo_objet_store_operator');
    final inkWell = tester.widget<InkWell>(
      find.descendant(
        of: find.byKey(const Key('app_nav_home_button')),
        matching: find.byType(InkWell),
      ),
    );

    expect(inkWell.onTap, isNull);
    expect(find.byKey(const Key('photo_ops_open_brand_manager')), findsNothing);
    expect(router.routeInformationProvider.value.uri.path, '/photo-ops');
  });

  testWidgets('Photo attendance requires a captured photo before recording', (
    tester,
  ) async {
    final service = _AttendanceService();
    await _pumpPhotoOps(
      tester,
      'photo_objet_store_operator',
      photoOpsState: PhotoOpsState(
        data: _dashboardData(),
        lastLoadedStoreId: _storeId,
      ),
      screen: PhotoOpsScreen(
        attendanceServiceOverride: service,
        attendancePhotoPickerOverride: () async => XFile.fromData(
          Uint8List.fromList([1, 2, 3]),
          name: 'attendance.jpg',
        ),
      ),
    );

    await tester.enterText(
      find.byKey(const Key('photo_ops_employee_number_field')),
      'PO-001',
    );
    await tester.tap(find.byKey(const Key('photo_ops_employee_clock_in')));
    await tester.pumpAndSettle();

    expect(service.uploadedEmployeeNumber, 'PO-001');
    expect(service.recordedPhotoUrl, 'https://example.test/attendance.jpg');
  });

  testWidgets('Photo payroll can be calculated and downloaded as Excel', (
    tester,
  ) async {
    final service = _PayrollService();
    String? savedName;
    List<int>? savedBytes;
    await _pumpPhotoOps(
      tester,
      'photo_objet_master',
      photoOpsState: PhotoOpsState(
        data: _dashboardData(),
        lastLoadedStoreId: _storeId,
      ),
      physicalSize: const Size(1440, 1200),
      screen: PhotoOpsScreen(
        payrollServiceOverride: service,
        payrollFileSaverOverride: (fileName, bytes) async {
          savedName = fileName;
          savedBytes = bytes;
        },
      ),
    );

    final sidebar = tester.widget<ToastSidebarPanel>(
      find.byType(ToastSidebarPanel),
    );
    sidebar.onItemSelected(3);
    await tester.pump();
    await tester.tap(find.byKey(const Key('photo_ops_payroll_export_button')));
    await tester.pumpAndSettle();

    expect(service.calculated, isTrue);
    expect(service.exported, isTrue);
    expect(savedName, startsWith('photo_payroll_'));
    expect(savedBytes, [1, 2, 3]);
  });

  testWidgets('Photo master menus render independent operational surfaces', (
    tester,
  ) async {
    final data = PhotoOpsDashboardData(
      kpi: const PhotoOpsKpi(
        allAttendanceEvents: 1,
        activeAttendanceEvents: 1,
        allInventoryAlerts: 1,
        activeInventoryAlerts: 1,
        activePayrollEstimate: 100000,
        activeStoreSales: 200000,
        networkSales: 900000,
        activeStoreTransactions: 2,
      ),
      recentAttendance: const [],
      inventoryAlerts: const [],
      inventoryItems: const [
        PhotoOpsInventoryRow(
          ingredientId: 'inventory-1',
          itemName: 'Photo paper',
          currentStock: 12,
          unit: 'box',
          reorderPoint: 5,
          needsReorder: false,
        ),
      ],
      payrollPreview: const [],
      salesSummary: [
        PhotoOpsSalesRow(
          storeId: _storeId,
          storeName: 'PHOTO OBJET DI AN',
          saleDate: DateTime(2026, 7, 22),
          grossSales: 200000,
          totalTransactions: 2,
          serviceAmount: 0,
          activeMachines: 2,
        ),
      ],
    );
    await _pumpPhotoOps(
      tester,
      'photo_objet_master',
      photoOpsState: PhotoOpsState(data: data, lastLoadedStoreId: _storeId),
      physicalSize: const Size(1440, 1800),
    );

    expect(
      tester.getSize(find.byKey(const Key('photo_ops_compact_context'))).height,
      lessThanOrEqualTo(56),
    );

    final sidebar = tester.widget<ToastSidebarPanel>(
      find.byType(ToastSidebarPanel),
    );
    expect(find.byKey(const Key('photo_ops_nav_priority')), findsNothing);
    expect(find.byKey(const Key('photo_ops_sales_export_button')), findsOne);
    sidebar.onItemSelected(0);
    await tester.pump();
    expect(
      tester
          .widget<ToastSidebarPanel>(find.byType(ToastSidebarPanel))
          .selectedIndex,
      0,
    );
    expect(find.byKey(const Key('photo_ops_sales_export_button')), findsOne);
    expect(
      find.byKey(const Key('photo_ops_inventory_adjust_inventory-1')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('photo_ops_sales_date_range_button')),
      findsOne,
    );
    expect(find.byType(ToastMetricStrip), findsOne);
    await tester.tap(
      find.byKey(const Key('photo_ops_sales_date_range_button')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(DateRangePickerDialog), findsOne);
    Navigator.of(tester.element(find.byType(DateRangePickerDialog))).pop();
    await tester.pumpAndSettle();

    sidebar.onItemSelected(2);
    await tester.pump();
    expect(
      find.byKey(const Key('photo_ops_sales_export_button')),
      findsNothing,
    );
    expect(
      find.byKey(const Key('photo_ops_inventory_adjust_inventory-1')),
      findsOne,
    );
    expect(find.byType(ToastMetricStrip), findsNothing);

    sidebar.onItemSelected(3);
    await tester.pump();
    expect(find.byKey(const Key('photo_ops_payroll_export_button')), findsOne);

    sidebar.onItemSelected(4);
    await tester.pump();
    await tester.tap(find.byKey(const Key('photo_ops_open_staff_management')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('employee_management_destination')), findsOne);
  });
}
