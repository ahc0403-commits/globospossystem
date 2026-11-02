import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/auth/operation_scope_provider.dart';
import 'package:globos_pos_system/core/services/pin_service.dart';
import 'package:globos_pos_system/features/admin/providers/admin_audit_provider.dart';
import 'package:globos_pos_system/features/admin/providers/daily_closing_provider.dart';
import 'package:globos_pos_system/features/admin/providers/settings_provider.dart';
import 'package:globos_pos_system/features/admin/tabs/reports_tab.dart';
import 'package:globos_pos_system/features/admin/tabs/settings_tab.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/auth/operation_scope_binding.dart';
import 'package:globos_pos_system/features/report/menu_sales_analytics.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

PosAuthState _state(String actor) => PosAuthState(
  user: User(
    id: actor,
    appMetadata: const {},
    userMetadata: const {},
    aud: 'authenticated',
    createdAt: '2026-11-01T00:00:00Z',
  ),
  role: 'store_admin',
  storeId: 'store-a',
  primaryStoreId: 'store-a',
  accessibleStores: const [AccessibleStore(id: 'store-a', name: 'Store A')],
);

class _Auth extends AuthNotifier {
  _Auth(SupabaseClient client) : super(client: client) {
    state = _state('actor-a');
  }
  void publish(PosAuthState next) {
    state = next;
  }
}

class _Pins extends PinService {
  var reads = 0;
  @override
  Future<bool> hasPayrollPin(String storeId) async {
    reads++;
    return true;
  }

  @override
  Future<bool> hasDiscountManagerPin(String storeId) async {
    reads++;
    return true;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late SupabaseClient client;
  late ProviderContainer container;
  late _Auth auth;
  late _Pins pins;
  var storeReads = 0;
  var userReads = 0;
  var reportReads = 0;
  Completer<void>? reportGate;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    storeReads = 0;
    userReads = 0;
    reportReads = 0;
    reportGate = null;
    pins = _Pins();
    client = SupabaseClient(
      'https://view-fixture.invalid',
      'fixture-anon',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        Object row;
        if (request.url.path.endsWith('/restaurants')) {
          storeReads++;
          row = {
            'id': 'store-a',
            'name': 'Store A',
            'address': 'A',
            'operation_mode': 'standard',
            'per_person_charge': null,
          };
        } else if (request.url.path.endsWith('/users')) {
          userReads++;
          row = {
            'full_name': request.url.queryParameters['auth_id']!.substring(3),
            'role': 'store_admin',
          };
        } else if (request.url.path.endsWith('/get_store_report_summary_v2')) {
          reportReads++;
          final amount = reportReads * 100;
          final body = jsonDecode(request.body) as Map;
          final gate = reportGate;
          reportGate = null;
          await gate?.future;
          row = {
            'version': 2,
            'store_id': body['p_store_id'],
            'from_date': body['p_from_date'],
            'to_date': body['p_to_date'],
            for (final key in [
              'dine_in',
              'delivery',
              'service',
              'cash',
              'card',
              'bank',
              'pay',
              'cancelled_amount',
              'total_orders',
              'completed_orders',
              'paid_orders',
              'open_orders',
              'cancelled_orders',
              'cancelled_items',
              'variance',
              'missing_proof_count',
              'failed_einvoice_count',
              'proof_pct',
            ])
              key: key == 'dine_in' ? amount : 0,
            for (final key in [
              'missing_proof',
              'einvoice_issues',
              'hourly',
              'methods',
              'daily',
            ])
              key: [],
          };
        } else {
          throw StateError('Unexpected fixture request ${request.url.path}');
        }
        return http.Response(
          jsonEncode(row),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    auth = _Auth(client);
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith((ref) => auth),
        operationScopeProvider.overrideWith(
          (ref) => bindOperationScope(ref, authProvider),
        ),
        settingsReadClientProvider.overrideWithValue(client),
        reportReadClientProvider.overrideWithValue(client),
        adminAuditTraceProvider.overrideWith((ref, store) async => []),
        dailyClosingHistoryProvider.overrideWith((ref, store) async => []),
        menuSalesAnalyticsProvider.overrideWith(
          (ref, params) async => MenuSalesAnalytics.fromJson(const {}),
        ),
      ],
    );
    container.read(operationScopeProvider);
  });
  tearDown(() async {
    container.dispose();
    await client.dispose();
  });

  Future<void> show(WidgetTester tester, Widget child) async {
    tester.view.physicalSize = const Size(1400, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          locale: const Locale('ko'),
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
    await tester.pumpAndSettle();
  }

  testWidgets(
    'settings reloads the same store on actor/access change, but not token display refresh',
    (tester) async {
      await show(tester, SettingsTab(pinServiceOverride: pins));
      expect(storeReads, 1);
      expect(userReads, 1);
      expect(pins.reads, 2);
      expect(container.read(settingsProvider).fullName, 'actor-a');
      final old = container.read(settingsProvider.notifier);
      auth.publish(_state('actor-b'));
      await tester.pumpAndSettle();
      expect(old.mounted, isFalse);
      expect(container.read(settingsProvider).fullName, 'actor-b');
      expect(storeReads, 2);
      expect(userReads, 2);
      expect(pins.reads, 4);
      auth.publish(_state('actor-b').copyWith(extraPermissions: ['reports']));
      await tester.pumpAndSettle();
      expect(storeReads, 3);
      expect(userReads, 3);
      expect(pins.reads, 6);
      auth.publish(
        _state('actor-b').copyWith(
          extraPermissions: ['reports'],
          isLoading: true,
          errorMessage: 'transient',
        ),
      );
      await tester.pumpAndSettle();
      expect(storeReads, 3);
      expect(pins.reads, 6);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  test('twenty identical report refreshes share one pending RPC', () async {
    final n = container.read(reportProvider.notifier);
    final gate = reportGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final first = n.loadReport('store-a');
    final pending = [for (var i = 0; i < 20; i++) n.loadReport('store-a')];
    expect(pending.every((p) => identical(p, first)), isTrue);
    for (var i = 0; i < 100 && reportReads == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(reportReads, 1);
    gate.complete();
    await Future.wait([first, ...pending]);
    expect(reportReads, 1);
    await n.loadReport('store-a');
    expect(reportReads, 2);
  });

  test('rapid report filters retain only the latest queued query', () async {
    final n = container.read(reportProvider.notifier);
    final gate = reportGate = Completer<void>();
    addTearDown(() {
      if (!gate.isCompleted) gate.complete();
    });
    final first = n.loadReport('store-a');
    for (var i = 0; i < 100 && reportReads == 0; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(reportReads, 1);
    final calls = [
      for (var i = 1; i <= 100; i++)
        n.setDateRange(DateTime(2026, 1, i), DateTime(2026, 1, i), 'store-a'),
    ];
    expect(n.state.summary, isNull);
    expect(n.state.isLoading, isTrue);
    expect(reportReads, 1);
    gate.complete();
    await Future.wait([first, ...calls]);
    expect(reportReads, 2);
    expect(n.state.startDate, DateTime(2026, 1, 100));
    expect(n.state.summary!.dineInRevenue, 200);
    expect(n.state.error, isNull);
    expect(n.state.isLoading, isFalse);
  });

  testWidgets(
    'report reloads without a store switch and discards an older actor response',
    (tester) async {
      await show(tester, const ReportsTab());
      expect(reportReads, 1);
      final old = container.read(reportProvider.notifier);
      final gate = reportGate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final pending = old.loadReport('store-a');
      // A request-owned native JSON worker starts asynchronously. Wait until
      // this specific old request has actually reached the response gate.
      for (var i = 0; i < 200 && reportReads < 2; i++) {
        await tester.pump();
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 10)),
        );
      }
      expect(reportReads, 2);
      auth.publish(_state('actor-b'));
      await tester.pumpAndSettle();
      expect(reportReads, 3);
      expect(old.mounted, isFalse);
      expect(container.read(reportProvider).summary!.dineInRevenue, 300);
      gate.complete();
      await pending;
      await tester.pumpAndSettle();
      expect(container.read(reportProvider).summary!.dineInRevenue, 300);
      expect(old.exportToExcel(), isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
