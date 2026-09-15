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

  test('migration enforces BM role, store scope, and server pagination', () {
    final migration = File(
      'supabase/migrations/20260915120000_bm_service_cancellation_history.sql',
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
  });

  testWidgets('service and cancellation buttons load separate histories', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final servicePage = _widgetPage();
    final cancellationPage = _cancellationWidgetPage();
    final loader = _FakeHistoryLoader(
      servicePage,
      resultsByType: {
        BmMenuHistoryType.service: servicePage,
        BmMenuHistoryType.cancellation: cancellationPage,
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
