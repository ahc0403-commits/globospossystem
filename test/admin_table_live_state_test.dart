import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';
import 'package:globos_pos_system/features/admin/admin_screen.dart';
import 'package:globos_pos_system/features/admin/providers/admin_audit_provider.dart';
import 'package:globos_pos_system/features/admin/providers/tables_provider.dart';
import 'package:globos_pos_system/features/admin/tabs/tables_tab.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/order/order_provider.dart';
import 'package:globos_pos_system/features/payment/payment_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Auth extends AuthNotifier {
  _Auth() {
    state = const PosAuthState(role: 'store_admin', storeId: 'store-a');
  }

  void changeStore() => state = state.copyWith(storeId: 'store-b');
}

class _Tables extends TablesNotifier {
  _Tables(super.storeId) {
    publish();
  }

  void publish({int seats = 4}) {
    state = TablesState(
      tables: [
        {
          'id': 'table-$storeId',
          'restaurant_id': storeId,
          'table_number': storeId == 'store-a' ? '1401' : '1101',
          'seat_count': seats,
          'status': 'available',
          'floor_label': '1F',
        },
      ],
    );
  }

  @override
  Future<void> fetchTables({bool showLoading = true}) async {}
}

class _Orders extends OrderNotifier {
  @override
  Future<void> loadActiveOrder(
    String tableId,
    String storeId, {
    bool syncOffline = true,
  }) async {}
}

class _Payments extends PaymentNotifier {
  @override
  Future<void> loadOrders(String storeId) async {}
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'test-anon',
      authOptions: const FlutterAuthClientOptions(
        detectSessionInUri: false,
        localStorage: EmptyLocalStorage(),
        autoRefreshToken: false,
      ),
    );
  });

  testWidgets(
    'table detail survives live reconciliation and updates data, but clears on store change',
    (tester) async {
      tester.view.physicalSize = const Size(1600, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final auth = _Auth();
      final events = StreamController<PosLiveEvent>.broadcast();
      final tables = <String, _Tables>{};
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) => const AdminScreen(initialTabIndex: 0),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith((ref) => auth),
            posLiveEventsProvider.overrideWith((ref, store) => events.stream),
            serviceConnectivityProvider.overrideWith(
              (ref) => Stream.value(
                const ServiceConnectivityState(
                  kind: ServiceConnectivityKind.online,
                ),
              ),
            ),
            adminAuditTraceProvider.overrideWith((ref, store) async => []),
            tablesProvider.overrideWith(
              (ref, store) => tables.putIfAbsent(store, () => _Tables(store)),
            ),
            orderProvider.overrideWith((ref) => _Orders()),
            paymentProvider.overrideWith((ref) => _Payments()),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.tap(find.text('1401').first);
      await tester.pump(const Duration(milliseconds: 300));
      const selected = ValueKey<String>('admin-order-table-store-a');
      expect(find.byKey(selected), findsOneWidget);
      final original = tester.state(find.byType(TablesTab));

      for (final event in [
        const PosLiveEvent.fallback(),
        const PosLiveEvent(
          domain: 'tables',
          sourceTable: 'tables',
          eventType: 'UPDATE',
          restaurantId: 'store-a',
        ),
        const PosLiveEvent(
          domain: 'payments',
          sourceTable: 'payments',
          eventType: 'INSERT',
          restaurantId: 'store-a',
        ),
      ]) {
        events.add(event);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 300));
        expect(find.byKey(selected), findsOneWidget);
        expect(tester.state(find.byType(TablesTab)), same(original));
      }

      tables['store-a']!.publish(seats: 6);
      await tester.pump();
      expect(find.byKey(selected), findsOneWidget);
      final context = tester.element(find.byType(TablesTab));
      expect(
        find.text(AppLocalizations.of(context)!.waiterSeatCount(6)),
        findsWidgets,
      );

      auth.changeStore();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(selected), findsNothing);
      expect(find.text('1101'), findsWidgets);
      expect(tester.state(find.byType(TablesTab)), isNot(same(original)));
      await tester.pumpWidget(const SizedBox.shrink());
      await events.close();
    },
  );
}
