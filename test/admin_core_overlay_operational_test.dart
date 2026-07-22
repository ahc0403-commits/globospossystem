import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/core/services/menu_service.dart';
import 'package:globos_pos_system/core/services/pin_service.dart';
import 'package:globos_pos_system/core/services/printer_destination_service.dart';
import 'package:globos_pos_system/core/services/attendance_service.dart';
import 'package:globos_pos_system/core/services/tables_service.dart';
import 'package:globos_pos_system/features/admin/providers/admin_audit_provider.dart';
import 'package:globos_pos_system/features/admin/providers/menu_provider.dart';
import 'package:globos_pos_system/features/admin/providers/printer_destinations_provider.dart';
import 'package:globos_pos_system/features/admin/providers/settings_provider.dart';
import 'package:globos_pos_system/features/admin/providers/staff_provider.dart';
import 'package:globos_pos_system/features/admin/providers/tables_provider.dart';
import 'package:globos_pos_system/features/admin/tabs/menu_tab.dart';
import 'package:globos_pos_system/features/admin/tabs/attendance_tab.dart';
import 'package:globos_pos_system/features/admin/tabs/qc_tab.dart';
import 'package:globos_pos_system/features/admin/tabs/settings_tab.dart';
import 'package:globos_pos_system/features/admin/tabs/staff_tab.dart';
import 'package:globos_pos_system/features/admin/tabs/tables_tab.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/order/order_provider.dart';
import 'package:globos_pos_system/features/qc/qc_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '7f6c9d22-6d84-4c7f-b923-79c81c4015d1';
const _tableId = '2d6f0ea0-3940-43cb-9378-e8ce45e77d4e';
const _categoryId = 'b77cfb5d-d565-4fc7-a924-b966559202ef';
const _emptyCategoryId = '7f16ab34-c423-4df3-a8b0-c9c754d64f29';
const _menuItemId = 'e28fa085-bdf1-49bc-a728-370ee5a8a433';

const _authState = PosAuthState(
  role: 'store_admin',
  storeId: _storeId,
  primaryStoreId: _storeId,
  accessibleStores: [AccessibleStore(id: _storeId, name: 'GLOBOS Nguyễn Huệ')],
);

class _AuthNotifier extends AuthNotifier {
  _AuthNotifier([PosAuthState initialState = _authState]) : super() {
    state = initialState;
  }

  @override
  Future<void> logout() async {}

  @override
  Future<void> setActiveStore(String storeId) async {}
}

class _OrderNotifier extends OrderNotifier {
  @override
  void clearSession() {}
}

class _TablesNotifier extends TablesNotifier {
  _TablesNotifier() : super(_storeId) {
    state = const TablesState(
      tables: [
        {
          'id': _tableId,
          'restaurant_id': _storeId,
          'table_number': 'A1',
          'seat_count': 4,
          'status': 'available',
          'floor_label': 'Ground',
          'layout_x': 0.08,
          'layout_y': 0.08,
          'layout_w': 0.2,
          'layout_h': 0.16,
          'layout_sort_order': 1,
        },
      ],
    );
  }

  int addCalls = 0;
  int editCalls = 0;

  @override
  Future<void> fetchTables({bool showLoading = true}) async {}

  @override
  Future<bool> addTable(
    String tableNumber,
    int seatCount, {
    String floorLabel = '1F',
  }) async {
    addCalls += 1;
    return true;
  }

  @override
  Future<bool> updateTableDetails({
    required String tableId,
    required String tableNumber,
    required int seatCount,
    required String floorLabel,
  }) async {
    editCalls += 1;
    return true;
  }
}

class _TablesService extends TablesService {
  int qrCalls = 0;

  @override
  Future<List<Map<String, dynamic>>> getOrCreateTableQrs({
    required String storeId,
    List<String>? tableIds,
  }) async => [
    {
      'token_id': 'operational-token-id',
      'table_id': _tableId,
      'table_number': 'A1',
      'floor_label': 'Ground',
      'layout_sort_order': 1,
      'store_name': 'GLOBOS Nguyễn Huệ',
      'token': 'operational-table-token',
    },
  ];

  @override
  Future<Map<String, dynamic>> generateTableQr(String tableId) async {
    qrCalls += 1;
    return const {'token': 'rotated-operational-table-token'};
  }
}

class _MenuNotifier extends MenuNotifier {
  _MenuNotifier() : super(_storeId) {
    state = const MenuState(
      categories: AsyncValue.data([
        {'id': _categoryId, 'name': 'Phở'},
        {'id': _emptyCategoryId, 'name': 'Món mới'},
      ]),
      items: AsyncValue.data([
        {
          'id': _menuItemId,
          'category_id': _categoryId,
          'name': 'Phở bò đặc biệt',
          'price': 85000,
          'is_available': true,
          'is_visible_public': true,
        },
      ]),
      selectedCategoryId: _categoryId,
    );
  }

  int addCategoryCalls = 0;
  int editCategoryCalls = 0;
  int deleteCategoryCalls = 0;
  int addItemCalls = 0;
  int editItemCalls = 0;
  int importCalls = 0;

  @override
  Future<void> fetchAll() async {}

  @override
  Future<void> fetchCategories() async {}

  @override
  Future<void> fetchItems() async {}

  @override
  Future<bool> addCategory({
    required String nameKo,
    required String nameVi,
    required String nameEn,
  }) async {
    addCategoryCalls += 1;
    return true;
  }

  @override
  Future<bool> updateCategory({
    required String categoryId,
    required String nameKo,
    required String nameVi,
    required String nameEn,
  }) async {
    editCategoryCalls += 1;
    return true;
  }

  @override
  Future<bool> deleteCategory(String categoryId) async {
    deleteCategoryCalls += 1;
    return true;
  }

  @override
  Future<bool> addMenuItem({
    required String categoryId,
    required String nameKo,
    required String nameVi,
    required String nameEn,
    required double price,
  }) async {
    addItemCalls += 1;
    return true;
  }

  @override
  Future<bool> updateMenuItem({
    required String itemId,
    required String nameKo,
    required String nameVi,
    required String nameEn,
    required double price,
  }) async {
    editItemCalls += 1;
    return true;
  }

  @override
  Future<MenuImportResult?> importMenuItems(
    List<Map<String, dynamic>> rows,
  ) async {
    importCalls += 1;
    return MenuImportResult(
      importedItemCount: rows.length,
      createdCategoryCount: 1,
    );
  }
}

class _StaffNotifier extends StaffNotifier {
  _StaffNotifier() {
    state = StaffState(
      staff: [
        StaffMember(
          id: 'a6acd6ca-5e77-465f-a52c-09a44a8b502a',
          employeeNumber: 'NV-001',
          fullName: 'Nguyễn Minh Anh',
          role: 'manager',
          isActive: true,
          createdAt: DateTime(2026, 7, 1),
          phone: '0901234567',
        ),
      ],
    );
  }

  int createCalls = 0;
  int deactivateCalls = 0;

  @override
  Future<void> loadStaff(String storeId) async {}

  @override
  Future<void> createStaff({
    required String storeId,
    required String fullName,
    required String role,
    String? phone,
    String? bankName,
    String? bankAccountNumber,
    String? bankAccountHolder,
    double? hourlyRate,
    String scheduledStart = '09:00',
    String nightStart = '22:00',
    double nightMultiplier = 1.3,
    double holidayMultiplier = 3,
    int lateThresholdMinutes = 60,
    double lateReviewHourlyMultiplier = 2,
  }) async {
    createCalls += 1;
    state = state.copyWith(
      isCreating: false,
      clearError: true,
      lastCreatedEmployee: StaffMember(
        id: 'e605c3c7-dad0-4b0a-83a1-cb09fa4b0c62',
        employeeNumber: 'NV-002',
        fullName: fullName,
        role: role,
        isActive: true,
        createdAt: DateTime(2026, 7, 18),
        phone: phone,
        bankName: bankName,
        bankAccountNumber: bankAccountNumber,
        bankAccountHolder: bankAccountHolder,
      ),
    );
  }

  @override
  Future<void> deactivateStaff({
    required String employeeId,
    required String storeId,
  }) async {
    deactivateCalls += 1;
    state = state.copyWith(clearError: true);
  }
}

class _AttendanceNotifier extends AttendanceNotifier {
  _AttendanceNotifier() {
    state = AttendanceState(
      logs: [
        AttendanceRecord(
          id: '157c9fe1-f243-46ec-a0ed-ecf5bac82023',
          userId: 'a6acd6ca-5e77-465f-a52c-09a44a8b502a',
          userName: 'Nguyễn Minh Anh',
          type: 'clock_in',
          loggedAt: DateTime(2026, 7, 18, 8, 5),
          userRole: 'waiter',
        ),
      ],
    );
  }

  @override
  Future<void> loadLogs(String storeId, {DateTime? date}) async {}
}

class _QcTemplateNotifier extends QcTemplateNotifier {
  _QcTemplateNotifier() {
    state = const QcTemplateState(
      templates: [
        {
          'id': 'qc-template-cleanliness',
          'restaurant_id': _storeId,
          'category': 'Vệ sinh',
          'criteria_text': 'Khu vực phục vụ sạch sẽ',
          'sort_order': 1,
          'is_global': false,
        },
      ],
    );
  }

  int addCalls = 0;

  @override
  Future<void> loadTemplates(String storeId) async {}

  @override
  Future<void> addTemplate({
    required String storeId,
    required String category,
    required String criteriaText,
    String? criteriaPhotoUrl,
    int sortOrder = 0,
  }) async {
    addCalls += 1;
  }
}

class _QcCheckNotifier extends QcCheckNotifier {
  _QcCheckNotifier() {
    final now = DateTime.now();
    final day = DateTime(now.year, now.month, now.day);
    final weekStart = day.subtract(Duration(days: day.weekday - 1));
    final checkDate = _isoDate(weekStart);
    state = QcCheckState(
      checks: [
        {
          'id': 'qc-check-operational',
          'template_id': 'qc-template-cleanliness',
          'check_date': checkDate,
          'result': 'pass',
          'note': 'Đã kiểm tra đầu ca',
          'evidence_photo_url': 'https://fixture.invalid/qc-evidence.jpg',
        },
      ],
      dateRangeChecks: [
        {
          'id': 'qc-check-operational',
          'template_id': 'qc-template-cleanliness',
          'check_date': checkDate,
          'result': 'pass',
          'evidence_photo_url': 'https://fixture.invalid/qc-evidence.jpg',
          'qc_templates': {
            'category': 'Vệ sinh',
            'criteria_text': 'Khu vực phục vụ sạch sẽ',
          },
        },
      ],
    );
  }

  static String _isoDate(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  String get firstCheckDate => state.checks.first['check_date']!.toString();

  @override
  Future<void> loadWeek({
    required String storeId,
    required DateTime weekStart,
  }) async {}

  @override
  Future<void> loadDateRange({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) async {}
}

class _QcFollowupNotifier extends QcFollowupNotifier {
  @override
  Future<void> load(String storeId, {String? statusFilter}) async {}
}

class _SettingsNotifier extends SettingsNotifier {
  _SettingsNotifier() {
    state = const SettingsState(
      storeId: _storeId,
      restaurantName: 'GLOBOS Nguyễn Huệ',
      address: '22 Nguyễn Huệ, Quận 1, TP.HCM',
      operationMode: 'standard',
      perPersonCharge: 0,
      fullName: 'Nguyễn Quản Lý',
      role: 'store_admin',
    );
  }

  @override
  Future<void> loadSettings(String storeId, String authUid) async {}
}

class _PrinterDestinationsNotifier extends PrinterDestinationsNotifier {
  _PrinterDestinationsNotifier() : super(_storeId) {
    state = const PrinterDestinationsState(
      destinations: [
        PrinterDestinationConfig(
          id: 'printer-kitchen-main',
          storeId: _storeId,
          name: 'Bếp chính',
          ip: '192.168.10.51',
          port: 9100,
          purpose: 'kitchen',
          isActive: true,
        ),
      ],
    );
  }

  int saveCalls = 0;

  @override
  Future<void> fetchDestinations({bool showLoading = true}) async {}

  @override
  Future<bool> upsertDestination(PrinterDestinationDraft draft) async {
    saveCalls += 1;
    return true;
  }
}

class _PinService extends PinService {
  int clearCalls = 0;

  @override
  Future<String?> fetchPinHash(String storeId) async => hashPin('2468');

  @override
  Future<bool> hasDiscountManagerPin(String storeId) async => true;

  @override
  Future<bool> verifyPin(String storeId, String enteredPin) async =>
      enteredPin == '2468';

  @override
  Future<void> clearPin(String storeId) async {
    clearCalls += 1;
  }
}

class _AttendanceService extends AttendanceService {
  @override
  Future<List<Map<String, dynamic>>> fetchStaffList(String storeId) async => [
    {
      'id': 'attendance-staff-1',
      'full_name': 'Nguyễn Minh Anh',
      'role': 'waiter',
    },
  ];

  @override
  Future<List<Map<String, dynamic>>> fetchLogs({
    required String storeId,
    required DateTime from,
    required DateTime to,
  }) async => [
    {
      'id': 'attendance-log-1',
      'restaurant_id': _storeId,
      'user_id': 'attendance-staff-1',
      'type': 'clock_in',
      'logged_at': DateTime.now()
          .subtract(const Duration(hours: 8))
          .toUtc()
          .toIso8601String(),
      'users': {
        'id': 'attendance-staff-1',
        'full_name': 'Nguyễn Minh Anh',
        'role': 'waiter',
      },
    },
    {
      'id': 'attendance-log-2',
      'restaurant_id': _storeId,
      'user_id': 'attendance-staff-1',
      'type': 'clock_out',
      'logged_at': DateTime.now().toUtc().toIso8601String(),
      'users': {
        'id': 'attendance-staff-1',
        'full_name': 'Nguyễn Minh Anh',
        'role': 'waiter',
      },
    },
  ];
}

Future<void> _pump(
  WidgetTester tester, {
  required Widget child,
  required List<Override> overrides,
  PosAuthState authState = _authState,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 900);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _AuthNotifier(authState)),
        orderProvider.overrideWith((ref) => _OrderNotifier()),
        adminAuditTraceProvider.overrideWith(
          (ref, storeId) => Future.value(const []),
        ),
        ...overrides,
      ],
      child: MaterialApp(
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
        home: Scaffold(body: child),
      ),
    ),
  );
  await tester.pump();
}

Finder _dialogAction(Key dialogKey, Type type) => find.descendant(
  of: find.byKey(dialogKey),
  matching: find.byWidgetPredicate((widget) => widget.runtimeType == type),
);

void _expectDialogButtonsAreTouchSized(WidgetTester tester, Key dialogKey) {
  final buttons = find.descendant(
    of: find.byKey(dialogKey),
    matching: find.byWidgetPredicate((widget) => widget is ButtonStyleButton),
  );
  expect(buttons, findsWidgets);
  for (final element in buttons.evaluate()) {
    final target = find.byElementPredicate((candidate) => candidate == element);
    final size = tester.getSize(target);
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
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

  testWidgets('all five table dialog entrypoints execute real workflows', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final notifier = _TablesNotifier();
    final service = _TablesService();
    await _pump(
      tester,
      child: TablesTab(tablesServiceOverride: service),
      overrides: [tablesProvider.overrideWith((ref, storeId) => notifier)],
    );

    await tester.tap(find.byKey(const Key('admin_tables_add_action')));
    await tester.pumpAndSettle();
    const addDialog = Key('admin_table_add_dialog');
    expect(find.byKey(addDialog), findsOneWidget);
    _expectDialogButtonsAreTouchSized(tester, addDialog);
    final addFields = find.descendant(
      of: find.byKey(addDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(addFields.at(0), 'A2');
    await tester.enterText(addFields.at(1), '6');
    await tester.enterText(addFields.at(2), 'Ground');
    await tester.tap(_dialogAction(addDialog, FilledButton));
    await tester.pumpAndSettle();
    expect(notifier.addCalls, 1);

    await tester.tap(find.text('A1').first);
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('admin_tables_edit_floor_label_action')),
    );
    await tester.pumpAndSettle();
    const editDialog = Key('admin_table_edit_dialog');
    expect(find.byKey(editDialog), findsOneWidget);
    _expectDialogButtonsAreTouchSized(tester, editDialog);
    final editFloor = find.byKey(
      const Key('admin_table_edit_floor_label_field'),
    );
    await tester.enterText(editFloor, 'Terrace');
    await tester.tap(_dialogAction(editDialog, FilledButton));
    await tester.pumpAndSettle();
    expect(notifier.editCalls, 1);

    await tester.tap(find.byKey(const Key('admin_tables_generate_qr_action')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('admin_table_qr_dialog')), findsOneWidget);
    expect(find.byKey(const Key('admin_table_qr_preview')), findsOneWidget);
    await tester.tap(find.byKey(const Key('admin_table_qr_replace_action')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('admin_table_qr_rotate_warning_dialog')),
      findsOneWidget,
    );
    await tester.tap(find.byKey(const Key('admin_table_qr_generate_confirm')));
    await tester.pumpAndSettle();
    expect(service.qrCalls, 1);
    expect(find.byKey(const Key('admin_table_qr_dialog')), findsOneWidget);
    expect(find.byKey(const Key('admin_table_qr_preview')), findsOneWidget);
    await tester.tap(
      find
          .descendant(
            of: find.byKey(const Key('admin_table_qr_dialog')),
            matching: find.byType(TextButton),
          )
          .first,
    );
    await tester.pumpAndSettle();

    final batchExport = find.byKey(
      const Key('admin_tables_qr_batch_export_action'),
    );
    await tester.ensureVisible(batchExport);
    await tester.tap(batchExport);
    await tester.pumpAndSettle();
    const batchFormatDialog = Key('admin_table_qr_batch_format_dialog');
    expect(find.byKey(batchFormatDialog), findsOneWidget);
    _expectDialogButtonsAreTouchSized(tester, batchFormatDialog);
    expect(
      tester
          .getSize(find.byKey(const Key('admin_table_qr_batch_pdf_action')))
          .height,
      greaterThanOrEqualTo(48),
    );
    await tester.tap(_dialogAction(batchFormatDialog, TextButton));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('all seven menu dialog entrypoints validate and save', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final notifier = _MenuNotifier();
    final importFiles = <XFile>[
      XFile.fromData(_menuWorkbookBytes(valid: true), name: 'menu-valid.xlsx'),
      XFile.fromData(
        _menuWorkbookBytes(valid: false),
        name: 'menu-invalid.xlsx',
      ),
    ];
    await _pump(
      tester,
      child: MenuTab(pickImportFile: () async => importFiles.removeAt(0)),
      overrides: [menuProvider.overrideWith((ref, storeId) => notifier)],
    );

    await tester.tap(find.byKey(const Key('admin_menu_import_excel_action')));
    await tester.pumpAndSettle();
    const importPreviewDialog = Key('admin_menu_import_preview_dialog');
    expect(find.byKey(importPreviewDialog), findsOneWidget);
    _expectDialogButtonsAreTouchSized(tester, importPreviewDialog);
    await tester.tap(_dialogAction(importPreviewDialog, FilledButton));
    await tester.pumpAndSettle();
    expect(notifier.importCalls, 1);

    await tester.tap(find.byKey(const Key('admin_menu_import_excel_action')));
    await tester.pumpAndSettle();
    const validationDialog = Key('admin_menu_import_validation_dialog');
    expect(find.byKey(validationDialog), findsOneWidget);
    _expectDialogButtonsAreTouchSized(tester, validationDialog);
    await tester.tap(_dialogAction(validationDialog, FilledButton));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_menu_add_category_action')));
    await tester.pumpAndSettle();
    const categoryDialog = Key('admin_menu_add_category_dialog');
    expect(find.byKey(categoryDialog), findsOneWidget);
    _expectDialogButtonsAreTouchSized(tester, categoryDialog);
    final categoryFields = find.descendant(
      of: find.byKey(categoryDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(categoryFields.at(0), '음료');
    await tester.enterText(categoryFields.at(1), 'Đồ uống');
    await tester.enterText(categoryFields.at(2), 'Drinks');
    await tester.tap(_dialogAction(categoryDialog, FilledButton));
    await tester.pumpAndSettle();
    expect(notifier.addCategoryCalls, 1);

    await tester.tap(find.byKey(const Key('admin_menu_add_item_action')));
    await tester.pumpAndSettle();
    const addItemDialog = Key('admin_menu_add_item_dialog');
    expect(find.byKey(addItemDialog), findsOneWidget);
    _expectDialogButtonsAreTouchSized(tester, addItemDialog);
    final addFields = find.descendant(
      of: find.byKey(addItemDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(addFields.at(0), '연유 커피');
    await tester.enterText(addFields.at(1), 'Cà phê sữa');
    await tester.enterText(addFields.at(2), 'Milk coffee');
    await tester.enterText(addFields.at(3), '45000');
    await tester.tap(_dialogAction(addItemDialog, FilledButton));
    await tester.pumpAndSettle();
    expect(notifier.addItemCalls, 1);

    await tester.tap(
      find.byKey(const Key('admin_menu_edit_item_$_menuItemId')),
    );
    await tester.pumpAndSettle();
    const editItemDialog = Key('admin_menu_edit_item_dialog');
    expect(find.byKey(editItemDialog), findsOneWidget);
    _expectDialogButtonsAreTouchSized(tester, editItemDialog);
    final editFields = find.descendant(
      of: find.byKey(editItemDialog),
      matching: find.byType(TextField),
    );
    await tester.enterText(editFields.at(0), 'Phở bò tái');
    await tester.tap(_dialogAction(editItemDialog, FilledButton));
    await tester.pumpAndSettle();
    expect(notifier.editItemCalls, 1);

    await tester.tap(
      find.byKey(const Key('admin_menu_edit_category_$_categoryId')),
    );
    await tester.pumpAndSettle();
    const editCategoryDialog = Key('admin_menu_edit_category_dialog');
    expect(find.byKey(editCategoryDialog), findsOneWidget);
    _expectDialogButtonsAreTouchSized(tester, editCategoryDialog);
    await tester.enterText(
      find.byKey(const Key('admin_menu_edit_category_name')),
      'Phở đặc biệt',
    );
    await tester.tap(_dialogAction(editCategoryDialog, FilledButton));
    await tester.pumpAndSettle();
    expect(notifier.editCategoryCalls, 1);

    await tester.tap(find.text('Món mới'));
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('admin_menu_delete_category_$_emptyCategoryId')),
    );
    await tester.pumpAndSettle();
    const deleteCategoryDialog = Key('admin_menu_delete_category_dialog');
    expect(find.byKey(deleteCategoryDialog), findsOneWidget);
    _expectDialogButtonsAreTouchSized(tester, deleteCategoryDialog);
    await tester.tap(
      find.byKey(const Key('admin_menu_delete_category_confirm')),
    );
    await tester.pumpAndSettle();
    expect(notifier.deleteCategoryCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all four staff sheet and dialog entrypoints execute', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final staffNotifier = _StaffNotifier();
    final attendanceNotifier = _AttendanceNotifier();
    await _pump(
      tester,
      child: const StaffTab(),
      overrides: [
        staffProvider.overrideWith((ref) => staffNotifier),
        attendanceProvider.overrideWith((ref) => attendanceNotifier),
      ],
    );
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('staff_root')), findsOneWidget);
    expect(find.text('Nguyễn Minh Anh'), findsWidgets);
    await tester.tap(find.byKey(const Key('staff_detail_secondary_detail')));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_staff_attendance_action')));
    await tester.pumpAndSettle();
    final attendanceSheet = find.byKey(
      const Key('admin_staff_attendance_sheet'),
    );
    expect(attendanceSheet, findsOneWidget);
    expect(find.textContaining('Nguyễn Minh Anh'), findsWidgets);
    Navigator.of(tester.element(attendanceSheet)).pop();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('staff_deactivate_employee_action')));
    await tester.pumpAndSettle();
    const deactivateDialog = Key('staff_deactivate_employee_dialog');
    expect(find.byKey(deactivateDialog), findsOneWidget);
    _expectDialogButtonsAreTouchSized(tester, deactivateDialog);
    await tester.tap(_dialogAction(deactivateDialog, FilledButton));
    await tester.pumpAndSettle();
    expect(staffNotifier.deactivateCalls, 1);

    await tester.tap(find.byKey(const Key('admin_staff_add_action')));
    await tester.pumpAndSettle();
    final addSheet = find.byKey(const Key('admin_staff_add_sheet'));
    expect(addSheet, findsOneWidget);
    expect(
      find.byKey(const Key('staff_employee_bank_name_field')),
      findsOneWidget,
    );
    final addButton = find.descendant(
      of: addSheet,
      matching: find.byType(FilledButton),
    );
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pump();
    expect(
      find.byKey(const Key('staff_create_validation_message')),
      findsOneWidget,
    );
    final fields = find.descendant(
      of: addSheet,
      matching: find.byType(TextField),
    );
    await tester.enterText(fields.at(0), 'Trần Gia Huy');
    await tester.enterText(
      find.byKey(const Key('staff_hourly_rate_field')),
      '30000',
    );
    await tester.ensureVisible(addButton);
    await tester.tap(addButton);
    await tester.pumpAndSettle();
    expect(staffNotifier.createCalls, 1);
    const employeeNumberDialog = Key('staff_created_employee_number_dialog');
    expect(find.byKey(employeeNumberDialog), findsOneWidget);
    expect(find.text('NV-002'), findsOneWidget);
    await tester.tap(_dialogAction(employeeNumberDialog, FilledButton));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('all three QC overlays execute and evidence target is 48dp', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final templateNotifier = _QcTemplateNotifier();
    final checkNotifier = _QcCheckNotifier();
    await _pump(
      tester,
      child: const QcTab(),
      overrides: [
        qcTemplateProvider.overrideWith((ref) => templateNotifier),
        qcCheckProvider.overrideWith((ref) => checkNotifier),
        qcFollowupProvider.overrideWith((ref) => _QcFollowupNotifier()),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('admin_qc_surface_2')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_qc_add_template_action')));
    await tester.pumpAndSettle();
    final templateSheet = find.byKey(const Key('admin_qc_template_sheet'));
    expect(templateSheet, findsOneWidget);
    final templateFields = find.descendant(
      of: templateSheet,
      matching: find.byType(TextField),
    );
    await tester.enterText(templateFields.at(0), 'An toàn thực phẩm');
    await tester.enterText(templateFields.at(1), 'Nhiệt độ bảo quản đạt chuẩn');
    await tester.tap(
      find.descendant(of: templateSheet, matching: find.byType(FilledButton)),
    );
    await tester.pumpAndSettle();
    expect(templateNotifier.addCalls, 1);

    await tester.tap(find.byKey(const Key('admin_qc_surface_1')));
    await tester.pumpAndSettle();
    final weeklyCell = find.byKey(
      Key(
        'admin_qc_weekly_cell_qc-template-cleanliness_'
        '${checkNotifier.firstCheckDate}',
      ),
    );
    await tester.ensureVisible(weeklyCell);
    await tester.tap(weeklyCell);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('admin_qc_cell_dialog')), findsOneWidget);
    await tester.tap(find.byKey(const Key('admin_qc_cell_evidence_action')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('admin_qc_image_dialog')), findsOneWidget);
    Navigator.of(
      tester.element(find.byKey(const Key('admin_qc_image_dialog'))),
    ).pop();
    await tester.pumpAndSettle();
    Navigator.of(
      tester.element(find.byKey(const Key('admin_qc_cell_dialog'))),
    ).pop();
    await tester.pumpAndSettle();

    final rangeSelector = find.byKey(const Key('admin_qc_range_mode_selector'));
    await tester.tap(
      find.descendant(of: rangeSelector, matching: find.byType(Text)).last,
    );
    await tester.pumpAndSettle();
    final thumbnail = find.byKey(const Key('admin_qc_evidence_thumbnail'));
    expect(thumbnail, findsOneWidget);
    expect(tester.getSize(thumbnail), const Size(48, 48));
    await tester.tap(thumbnail);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('admin_qc_image_dialog')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('all four Settings dialog entrypoints execute with store data', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final user = User.fromJson({
      'id': '9cc5a829-0f5e-4ed3-a98f-72f86cb86e77',
      'aud': 'authenticated',
      'role': 'authenticated',
      'email': 'manager@globos.test',
      'created_at': '2026-07-01T00:00:00.000Z',
    });
    final authState = PosAuthState(
      user: user,
      role: 'store_admin',
      storeId: _storeId,
      primaryStoreId: _storeId,
      accessibleStores: const [
        AccessibleStore(id: _storeId, name: 'GLOBOS Nguyễn Huệ'),
      ],
    );
    final pinService = _PinService();
    final destinationsNotifier = _PrinterDestinationsNotifier();
    await _pump(
      tester,
      authState: authState,
      child: SettingsTab(pinServiceOverride: pinService),
      overrides: [
        settingsProvider.overrideWith((ref) => _SettingsNotifier()),
        printerDestinationsProvider.overrideWith(
          (ref, storeId) => destinationsNotifier,
        ),
      ],
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('settings_category_payment')));
    await tester.pump();

    await tester.tap(
      find.byKey(const Key('settings_payroll_pin_change_action')),
    );
    await tester.pumpAndSettle();
    final payrollDialog = find.byKey(const Key('settings_payroll_pin_dialog'));
    expect(payrollDialog, findsOneWidget);
    final payrollFields = find.descendant(
      of: payrollDialog,
      matching: find.byType(TextField),
    );
    await tester.enterText(payrollFields.first, '12');
    await tester.tap(
      find.descendant(of: payrollDialog, matching: find.byType(FilledButton)),
    );
    await tester.pump();
    expect(find.textContaining('4'), findsWidgets);
    Navigator.of(tester.element(payrollDialog)).pop();
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('settings_discount_manager_pin_change_action')),
    );
    await tester.pumpAndSettle();
    final discountDialog = find.byKey(
      const Key('settings_discount_manager_pin_dialog'),
    );
    expect(discountDialog, findsOneWidget);
    Navigator.of(tester.element(discountDialog)).pop();
    await tester.pumpAndSettle();

    await tester.tap(
      find.byKey(const Key('settings_payroll_pin_clear_action')),
    );
    await tester.pumpAndSettle();
    expect(find.byType(Dialog), findsOneWidget);
    for (final digit in const ['2', '4', '6', '8']) {
      await tester.tap(find.widgetWithText(OutlinedButton, digit));
      await tester.pump();
    }
    final l10n = AppLocalizations.of(
      tester.element(find.byKey(const Key('settings_root'))),
    )!;
    await tester.tap(find.text(l10n.confirm));
    await tester.pumpAndSettle();
    expect(pinService.clearCalls, 1);

    await tester.tap(find.byKey(const Key('settings_category_receipt')));
    await tester.pump();
    await tester.ensureVisible(
      find.byKey(const Key('settings_printer_destination_add')),
    );
    await tester.tap(find.byKey(const Key('settings_printer_destination_add')));
    await tester.pumpAndSettle();
    final printerDialog = find.byKey(
      const Key('settings_printer_destination_dialog'),
    );
    expect(printerDialog, findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('settings_printer_destination_name')),
      'Bếp phụ',
    );
    await tester.enterText(
      find.byKey(const Key('settings_printer_destination_ip')),
      '192.168.10.52',
    );
    await tester.tap(
      find.descendant(of: printerDialog, matching: find.byType(FilledButton)),
    );
    await tester.pumpAndSettle();
    expect(destinationsNotifier.saveCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Attendance payroll unlock dialog executes with store logs', (
    tester,
  ) async {
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await _pump(
      tester,
      child: AttendanceTab(
        attendanceServiceOverride: _AttendanceService(),
        pinServiceOverride: _PinService(),
      ),
      overrides: const [],
    );
    await tester.pumpAndSettle();
    expect(find.text('Nguyễn Minh Anh'), findsWidgets);

    await tester.tap(
      find.byKey(const Key('attendance_payroll_secondary_detail')),
    );
    await tester.pumpAndSettle();
    final action = find.byKey(const Key('attendance_payroll_primary_action'));
    await tester.ensureVisible(action);
    await tester.tap(action);
    await tester.pumpAndSettle();

    final dialog = find.byKey(const Key('attendance_payroll_unlock_dialog'));
    expect(dialog, findsOneWidget);
    await tester.enterText(
      find.descendant(of: dialog, matching: find.byType(TextField)),
      '2468',
    );
    await tester.tap(
      find.descendant(of: dialog, matching: find.byType(FilledButton)),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('attendance_payroll_unlock_dialog')),
      findsNothing,
    );
    expect(tester.takeException(), isNull);
  });
}

Uint8List _menuWorkbookBytes({required bool valid}) {
  final workbook = Excel.createExcel();
  final sheet = workbook['메뉴등록'];
  sheet.appendRow(
    const [
      '매장코드',
      '카테고리명',
      '카테고리순서',
      '메뉴명',
      '설명',
      '가격(VND)',
      '판매가능',
      'QR메뉴노출',
      '메뉴순서',
    ].map(TextCellValue.new).toList(),
  );
  sheet.appendRow([
    TextCellValue('BT'),
    TextCellValue('분식'),
    IntCellValue(1),
    TextCellValue('떡볶이'),
    TextCellValue('매운맛'),
    IntCellValue(valid ? 50000 : 0),
    BoolCellValue(true),
    BoolCellValue(true),
    IntCellValue(1),
  ]);
  return Uint8List.fromList(workbook.encode()!);
}
