import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/permission_utils.dart';
import 'package:globos_pos_system/features/admin/providers/daily_closing_provider.dart';
import 'package:globos_pos_system/features/admin/tabs/reports_tab.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/report/bm_menu_exception_history.dart';
import 'package:globos_pos_system/features/report/menu_sales_analytics.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FakeHistoryLoader implements BmMenuExceptionHistoryLoader {
  _FakeHistoryLoader(this.result, {this.resultsByType = const {}});

  final BmMenuExceptionHistoryPage result;
  final Map<BmMenuHistoryType, BmMenuExceptionHistoryPage> resultsByType;
  int callCount = 0;
  int orderDetailCallCount = 0;
  String? requestedOrderId;
  final requestedTypes = <BmMenuHistoryType>[];

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
    callCount++;
    requestedTypes.add(historyType);
    return resultsByType[historyType] ?? result;
  }

  @override
  Future<BmOriginalOrderDetail> fetchOrderDetail({
    required String orderId,
  }) async {
    orderDetailCallCount++;
    requestedOrderId = orderId;
    return _originalOrderDetailFixture();
  }
}

final _bmTestClient = SupabaseClient('http://localhost:54321', 'test-anon-key');

class _BmAuthNotifier extends AuthNotifier {
  _BmAuthNotifier() : super(client: _bmTestClient) {
    _bmTestClient.auth.stopAutoRefresh();
    state = const PosAuthState(
      role: 'brand_admin',
      storeId: 'store-1',
      primaryStoreId: 'store-1',
      accessibleStores: [AccessibleStore(id: 'store-1', name: 'Bunsik')],
    );
  }
}

class _IdleReportNotifier extends ReportNotifier {
  _IdleReportNotifier() {
    state = ReportState(
      startDate: DateTime(2026, 9, 1),
      endDate: DateTime(2026, 9, 15),
    );
  }

  @override
  Future<void> loadReport(String storeId) async {}
}

BmMenuExceptionHistoryPage _widgetPage() {
  return BmMenuExceptionHistoryPage.fromJson({
    'items': [
      {
        'source_kind': 'service',
        'event_type': 'service_marked',
        'event_id': 'event-widget',
        'event_at': '2026-09-15T05:00:00Z',
        'store_id': 'store-1',
        'store_name': 'Bunsik',
        'order_id': 'order-widget',
        'order_number': '12345',
        'item_name': 'Service Tteokbokki',
        'quantity': 1,
        'unit_price': 50000,
        'reference_amount': 50000,
        'is_service_item': true,
        'actor_name': 'BM 1',
        'reason': 'guest recovery',
        'current_state': 'service',
        'data_incomplete': false,
      },
    ],
    'summary': {
      'total_rows': 1,
      'service_event_count': 1,
      'service_quantity': 1,
      'service_reference_amount': 50000,
      'cancellation_event_count': 0,
      'cancelled_quantity': 0,
      'cancelled_amount': 0,
      'reversal_event_count': 0,
    },
    'page': 0,
    'page_size': 50,
    'has_more': false,
    'fetched_at': '2026-09-15T06:00:00Z',
  });
}

BmMenuExceptionHistoryPage _cancellationWidgetPage() {
  return BmMenuExceptionHistoryPage.fromJson({
    'items': [
      {
        'source_kind': 'cancellation',
        'event_type': 'item_cancelled',
        'event_id': 'event-cancellation-widget',
        'event_at': '2026-09-15T05:30:00Z',
        'store_id': 'store-1',
        'store_name': 'Bunsik',
        'order_id': 'order-cancellation-widget',
        'order_number': '23456',
        'item_name': 'Cancelled Kimbap',
        'quantity': 2,
        'unit_price': 30000,
        'reference_amount': 60000,
        'cancelled_amount': 60000,
        'is_service_item': false,
        'actor_name': 'BM 1',
        'reason': 'guest request',
        'current_state': 'cancelled',
        'data_incomplete': false,
      },
    ],
    'summary': {
      'total_rows': 1,
      'service_event_count': 0,
      'service_quantity': 0,
      'service_reference_amount': 0,
      'cancellation_event_count': 1,
      'cancelled_quantity': 2,
      'cancelled_amount': 60000,
      'reversal_event_count': 0,
    },
    'page': 0,
    'page_size': 50,
    'has_more': false,
    'fetched_at': '2026-09-15T06:00:00Z',
  });
}

BmMenuExceptionHistoryPage _staffMealWidgetPage() {
  return BmMenuExceptionHistoryPage.fromJson({
    'items': [
      {
        'source_kind': 'staff_meal',
        'event_type': 'staff_meal_created',
        'event_id': 'event-staff-meal-widget',
        'event_at': '2026-09-15T05:45:00Z',
        'store_id': 'store-1',
        'store_name': 'Bunsik',
        'order_id': 'order-staff-meal-widget',
        'order_number': '34567',
        'item_name': 'Staff Bibimbap, Staff Soup',
        'quantity': 3,
        'unit_price': null,
        'reference_amount': 65000,
        'is_service_item': false,
        'actor_name': 'BM 1',
        'reason': 'staff dinner',
        'current_state': 'staff_meal_completed',
        'data_incomplete': false,
      },
    ],
    'summary': {
      'total_rows': 1,
      'service_event_count': 0,
      'service_quantity': 0,
      'service_reference_amount': 0,
      'cancellation_event_count': 0,
      'cancelled_quantity': 0,
      'cancelled_amount': 0,
      'staff_meal_event_count': 1,
      'staff_meal_quantity': 3,
      'staff_meal_reference_amount': 65000,
      'reversal_event_count': 0,
    },
    'page': 0,
    'page_size': 50,
    'has_more': false,
    'fetched_at': '2026-09-15T06:00:00Z',
  });
}

BmOriginalOrderDetail _originalOrderDetailFixture() {
  return BmOriginalOrderDetail.fromJson({
    'order_id': 'order-widget',
    'order_number': '12345',
    'created_at': '2026-09-15T04:30:00Z',
    'store_id': 'store-1',
    'store_name': 'Bunsik',
    'table_number': 'A1',
    'status': 'completed',
    'order_purpose': 'customer',
    'sales_channel': 'dine_in',
    'created_by_name': 'Waiter 1',
    'notes': 'Original guest order',
    'item_count': 2,
    'total_quantity': 3,
    'reference_amount': 65000,
    'items': [
      {
        'id': 'item-1',
        'name': 'Original Bibimbap',
        'quantity': 1,
        'unit_price': 45000,
        'reference_amount': 45000,
        'status': 'served',
        'is_service_item': false,
      },
      {
        'id': 'item-2',
        'name': 'Original Soup',
        'quantity': 2,
        'unit_price': 10000,
        'reference_amount': 20000,
        'status': 'served',
        'is_service_item': true,
      },
    ],
  });
}

Widget _historyApp({required String role, required _FakeHistoryLoader loader}) {
  return ProviderScope(
    overrides: [bmMenuHistoryRoleProvider.overrideWith((ref) => role)],
    child: MaterialApp(
      home: BmMenuExceptionHistoryScreen(
        stores: const [AccessibleStore(id: 'store-1', name: 'Bunsik')],
        initialStoreId: 'store-1',
        initialStartDate: DateTime(2026, 9, 1),
        initialEndDate: DateTime(2026, 9, 30),
        service: loader,
      ),
    ),
  );
}

void main() {
  test('BM menu history models preserve amounts and incomplete records', () {
    final page = BmMenuExceptionHistoryPage.fromJson({
      'items': [
        {
          'source_kind': 'cancellation',
          'event_type': 'item_cancelled',
          'event_id': 'event-1',
          'event_at': '2026-09-15T05:00:00Z',
          'store_id': 'store-1',
          'store_name': 'Bunsik',
          'order_id': 'order-1',
          'item_name': 'Tteokbokki',
          'quantity': '2',
          'unit_price': '50000',
          'reference_amount': '100000',
          'cancelled_amount': '108000',
          'is_service_item': false,
          'actor_name': 'BM 1',
          'current_state': 'restored',
          'data_incomplete': true,
        },
      ],
      'summary': {
        'total_rows': 1,
        'service_event_count': 0,
        'service_quantity': 0,
        'service_reference_amount': 0,
        'cancellation_event_count': 1,
        'cancelled_quantity': 2,
        'cancelled_amount': 108000,
        'reversal_event_count': 1,
      },
      'page': 0,
      'page_size': 50,
      'has_more': false,
      'fetched_at': '2026-09-15T06:00:00Z',
    });

    expect(page.items, hasLength(1));
    expect(page.items.single.cancelledAmount, 108000);
    expect(page.items.single.dataIncomplete, isTrue);
    expect(page.summary.cancelledQuantity, 2);
    expect(page.summary.cancelledAmount, 108000);
  });

  test('only brand_admin receives the BM history client permission', () {
    expect(
      PermissionUtils.canViewServiceCancellationHistory('brand_admin'),
      isTrue,
    );
    for (final role in [
      'admin',
      'store_admin',
      'cashier',
      'waiter',
      'super_admin',
      'photo_objet_master',
      null,
    ]) {
      expect(
        PermissionUtils.canViewServiceCancellationHistory(role),
        isFalse,
        reason: '$role must not receive BM history access',
      );
    }
  });

  test('staff meal models preserve their separate summary', () {
    final page = _staffMealWidgetPage();

    expect(page.items.single.sourceKind, 'staff_meal');
    expect(page.items.single.currentState, 'staff_meal_completed');
    expect(page.summary.staffMealEventCount, 1);
    expect(page.summary.staffMealQuantity, 3);
    expect(page.summary.staffMealReferenceAmount, 65000);
    expect(page.items.single.itemName, 'Staff Bibimbap, Staff Soup');
    expect(page.items.single.orderNumber, '34567');
  });

  test('original order detail preserves the full order and item states', () {
    final detail = _originalOrderDetailFixture();

    expect(detail.orderNumber, '12345');
    expect(detail.itemCount, 2);
    expect(detail.totalQuantity, 3);
    expect(detail.referenceAmount, 65000);
    expect(detail.items.map((item) => item.name), [
      'Original Bibimbap',
      'Original Soup',
    ]);
    expect(detail.items.last.isServiceItem, isTrue);
  });

  test('migration enforces BM role, store scope, and server pagination', () {
    final migration = File(
      'supabase/migrations/20260915180000_bm_order_drilldown_staff_meal_grouping.sql',
    ).readAsStringSync();
    final runtime = File(
      'supabase/tests/bm_menu_exception_history_test.sql',
    ).readAsStringSync();

    expect(migration, contains("v_actor.role <> 'brand_admin'"));
    expect(migration, contains('public.user_accessible_stores(auth.uid())'));
    expect(migration, contains('BM_MENU_HISTORY_FORBIDDEN'));
    expect(migration, contains('OFFSET v_page * v_page_size'));
    expect(migration, contains("'service_unmarked'"));
    expect(migration, contains("'order_restored'"));
    expect(migration, contains('order_cancellation_ledger'));
    expect(migration, contains('order_cancellation_reversals'));
    expect(migration, contains("order_row.order_purpose = 'staff_meal'"));
    expect(migration, contains("'staff_meal_created'"));
    expect(migration, contains('orders_bm_staff_meal_history_idx'));
    expect(migration, contains('string_agg('));
    expect(migration, contains('get_bm_order_history_detail'));
    expect(migration, contains("'order_number'"));
    expect(runtime, contains('Non-BM history access was not rejected'));
    expect(runtime, contains('BM out-of-scope store access was not rejected'));
    expect(runtime, contains('BM history aggregation mismatch'));
  });

  testWidgets('BM can load the history and open item details', (tester) async {
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final loader = _FakeHistoryLoader(_widgetPage());

    await tester.pumpWidget(_historyApp(role: 'brand_admin', loader: loader));
    await tester.pumpAndSettle();

    expect(loader.callCount, 1);
    expect(find.text('Service Tteokbokki'), findsOneWidget);
    await tester.tap(find.text('Service Tteokbokki'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('bm_menu_history_detail')), findsOneWidget);
    expect(find.text('guest recovery'), findsOneWidget);
  });

  testWidgets('non-BM cannot load the history screen data', (tester) async {
    final loader = _FakeHistoryLoader(_widgetPage());

    await tester.pumpWidget(_historyApp(role: 'store_admin', loader: loader));
    await tester.pumpAndSettle();

    expect(loader.callCount, 0);
    expect(
      find.text('Only BM accounts can view this history.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('bm_menu_history_list')), findsNothing);
  });

  testWidgets(
    'service and cancellation order numbers open the original order',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final servicePage = _widgetPage();
      final cancellationPage = _cancellationWidgetPage();
      final loader = _FakeHistoryLoader(
        servicePage,
        resultsByType: {BmMenuHistoryType.cancellation: cancellationPage},
      );

      await tester.pumpWidget(_historyApp(role: 'brand_admin', loader: loader));
      await tester.pumpAndSettle();

      await tester.tap(
        find.byKey(const Key('bm_original_order_order-widget_desktop_0')),
      );
      await tester.pumpAndSettle();
      expect(loader.requestedOrderId, 'order-widget');
      expect(find.byKey(const Key('bm_original_order_detail')), findsOneWidget);
      expect(find.text('Original order details #12345'), findsOneWidget);
      expect(find.text('Original Bibimbap'), findsOneWidget);
      expect(find.text('Original Soup'), findsOneWidget);

      await tester.tap(find.byKey(const Key('bm_original_order_close')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const Key('bm_menu_history_type_cancellation')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(
          const Key('bm_original_order_order-cancellation-widget_desktop_0'),
        ),
      );
      await tester.pumpAndSettle();
      expect(loader.orderDetailCallCount, 2);
      expect(loader.requestedOrderId, 'order-cancellation-widget');
      expect(find.byKey(const Key('bm_original_order_detail')), findsOneWidget);
    },
  );

  testWidgets('BM history stays usable on a phone-sized screen', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final loader = _FakeHistoryLoader(_widgetPage());

    await tester.pumpWidget(_historyApp(role: 'brand_admin', loader: loader));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('bm_menu_history_lookup')), findsOneWidget);
    expect(find.text('Service Tteokbokki'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('bm_original_order_order-widget_mobile_0')),
    );
    await tester.pumpAndSettle();
    expect(loader.requestedOrderId, 'order-widget');
    expect(find.byKey(const Key('bm_original_order_detail')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('type buttons load service, cancellation, and staff meals', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final servicePage = _widgetPage();
    final cancellationPage = _cancellationWidgetPage();
    final staffMealPage = _staffMealWidgetPage();
    final loader = _FakeHistoryLoader(
      servicePage,
      resultsByType: {
        BmMenuHistoryType.service: servicePage,
        BmMenuHistoryType.cancellation: cancellationPage,
        BmMenuHistoryType.staffMeal: staffMealPage,
      },
    );

    await tester.pumpWidget(_historyApp(role: 'brand_admin', loader: loader));
    await tester.pumpAndSettle();

    expect(loader.requestedTypes, [BmMenuHistoryType.all]);
    await tester.tap(
      find.byKey(const Key('bm_menu_history_type_service')).hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(loader.requestedTypes.last, BmMenuHistoryType.service);
    expect(find.text('Service Tteokbokki'), findsOneWidget);
    expect(find.text('Cancelled Kimbap'), findsNothing);

    await tester.tap(
      find.byKey(const Key('bm_menu_history_type_cancellation')).hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(loader.requestedTypes.last, BmMenuHistoryType.cancellation);
    expect(find.text('Service Tteokbokki'), findsNothing);
    expect(find.text('Cancelled Kimbap'), findsOneWidget);

    await tester.tap(
      find.byKey(const Key('bm_menu_history_type_staff_meal')).hitTestable(),
    );
    await tester.pumpAndSettle();
    expect(loader.requestedTypes.last, BmMenuHistoryType.staffMeal);
    expect(find.text('Service Tteokbokki'), findsNothing);
    expect(find.text('Cancelled Kimbap'), findsNothing);
    expect(find.text('Staff-meal order #34567'), findsOneWidget);
    expect(find.textContaining('Staff Bibimbap, Staff Soup'), findsOneWidget);
  });

  testWidgets(
    'BM report shows the history entry in the initial phone viewport',
    (tester) async {
      tester.view.physicalSize = const Size(390, 844);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith((ref) => _BmAuthNotifier()),
            reportProvider.overrideWith((ref) => _IdleReportNotifier()),
            menuSalesAnalyticsProvider.overrideWith(
              (ref, params) async => MenuSalesAnalytics.fromJson(const {}),
            ),
            dailyClosingHistoryProvider.overrideWith(
              (ref, storeId) async => const [],
            ),
          ],
          child: MaterialApp(
            locale: const Locale('ko'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: const [
              AppLocalizations.delegate,
              GlobalMaterialLocalizations.delegate,
              GlobalWidgetsLocalizations.delegate,
              GlobalCupertinoLocalizations.delegate,
            ],
            home: const ReportsTab(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('bm_menu_exception_history_entry')).hitTestable(),
        findsOneWidget,
      );
      await tester.tap(
        find.byKey(const Key('bm_menu_exception_history_entry')).hitTestable(),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const Key('bm_menu_exception_history_screen')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
}
