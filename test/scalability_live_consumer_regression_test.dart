import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/bank_transfer_alert_coordinator.dart';
import 'package:globos_pos_system/core/services/bank_transfer_alert_service.dart';
import 'package:globos_pos_system/core/services/bank_transfer_alert_sound.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';
import 'package:globos_pos_system/features/admin/admin_screen.dart';
import 'package:globos_pos_system/features/admin/providers/admin_scope_provider.dart';
import 'package:globos_pos_system/features/admin/tabs/attendance_tab.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const store = '7f6c9d22-6d84-4c7f-b923-79c81c4015d1';
const orderEvent = PosLiveEvent(
  domain: 'orders',
  sourceTable: 'orders',
  eventType: 'UPDATE',
  restaurantId: store,
);
const paymentEvent = PosLiveEvent(
  domain: 'payments',
  sourceTable: 'payments',
  eventType: 'INSERT',
  restaurantId: store,
);
const bankEvent = PosLiveEvent(
  domain: 'bank_transfer',
  sourceTable: 'sepay_transactions',
  eventType: 'INSERT',
  restaurantId: store,
);

class AuditAuth extends AuthNotifier {
  AuditAuth() : super() {
    state = const PosAuthState(role: 'store_admin');
  }
}

class AuditAlerts extends BankTransferAlertService {
  final started = DateTime.now().toUtc();
  final items = <BankTransferAlert>[];
  @override
  Future<void> registerPollingDevice(String id) async {}
  @override
  Future<bool> acknowledge(String id, {required bool spoken}) async => true;
  @override
  Future<BankTransferAlertCursor?> loadCursor(String id) async =>
      BankTransferAlertCursor(receivedAt: started, providerTransactionId: 0);
  @override
  Future<void> saveCursor(String id, BankTransferAlertCursor cursor) async {}
  @override
  Future<List<BankTransferAlert>> fetchAfter(
    String id,
    BankTransferAlertCursor cursor, {
    int limit = 100,
  }) async => items.where(cursor.isBefore).take(limit).toList();
}

class AuditSound extends BankTransferAlertSoundService {
  final amounts = <int>[];
  @override
  Future<void> prepare() async {}
  @override
  Future<void> play({required int amount}) async {
    amounts.add(amount);
  }
}

const delegates = [
  AppLocalizations.delegate,
  GlobalMaterialLocalizations.delegate,
  GlobalWidgetsLocalizations.delegate,
  GlobalCupertinoLocalizations.delegate,
];

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'http://127.0.0.1:54321',
      anonKey: 'audit-fixture',
    );
  });

  for (final signal in {
    'single': bankEvent,
    'merged': paymentEvent.merge(bankEvent),
    'merged with fallback': const PosLiveEvent.fallback().merge(bankEvent),
  }.entries) {
    testWidgets(
      'bank-transfer ${signal.key} alerts immediately and only once',
      (tester) async {
        final events = StreamController<PosLiveEvent>.broadcast();
        final alerts = AuditAlerts();
        final sound = AuditSound();
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              posLiveEventsProvider(store).overrideWith((ref) => events.stream),
            ],
            child: MaterialApp(
              locale: const Locale('vi'),
              supportedLocales: AppLocalizations.supportedLocales,
              localizationsDelegates: delegates,
              home: BankTransferAlertCoordinator(
                storeId: store,
                alertService: alerts,
                soundService: sound,
                pollInterval: const Duration(seconds: 2),
                child: const Scaffold(body: Text('POS')),
              ),
            ),
          ),
        );
        await tester.pump();
        alerts.items.add(
          BankTransferAlert(
            transactionId: 'audit-bank-transfer',
            providerTransactionId: 1,
            amount: 123456,
            gateway: 'MSB',
            receivedAt: alerts.started.add(const Duration(seconds: 1)),
          ),
        );
        events.add(signal.value);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        final immediate = List<int>.of(sound.amounts);
        await tester.pump(const Duration(seconds: 2));
        expect(sound.amounts, [
          123456,
        ], reason: 'existing polling fallback still delivers once');
        await tester.pumpWidget(const SizedBox.shrink());
        await events.close();
        expect(
          immediate,
          [123456],
          reason:
              'the latest bank-transfer INSERT must keep its realtime alert',
        );
      },
    );
  }

  testWidgets(
    'unrelated merged sales events preserve the existing attendance tab state',
    (tester) async {
      final events = StreamController<PosLiveEvent>.broadcast();
      final router = GoRouter(
        initialLocation: '/admin',
        routes: [
          GoRoute(
            path: '/admin',
            builder: (_, __) => const AdminScreen(initialTabIndex: 4),
          ),
        ],
      );
      addTearDown(router.dispose);
      tester.view.physicalSize = const Size(1440, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith((ref) => AuditAuth()),
            adminScopedStoreIdProvider.overrideWithValue(store),
            connectivityProvider.overrideWith((ref) => Stream.value(true)),
            posLiveEventsProvider(store).overrideWith((ref) => events.stream),
          ],
          child: MaterialApp.router(
            locale: const Locale('ko'),
            supportedLocales: AppLocalizations.supportedLocales,
            localizationsDelegates: delegates,
            routerConfig: router,
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      final before = tester.state(find.byType(AttendanceTab));
      events.add(orderEvent);
      await tester.pump();
      expect(
        identical(tester.state(find.byType(AttendanceTab)), before),
        isTrue,
        reason: 'control: an unrelated single event preserves the form',
      );
      events.add(orderEvent.merge(paymentEvent));
      await tester.pump();
      final preserved = identical(
        tester.state(find.byType(AttendanceTab)),
        before,
      );
      events.add(
        orderEvent.merge(
          const PosLiveEvent(
            domain: 'attendance',
            sourceTable: 'attendance',
            eventType: 'UPDATE',
            restaurantId: store,
          ),
        ),
      );
      await tester.pump();
      final refreshed = tester.state(find.byType(AttendanceTab));
      expect(
        identical(refreshed, before),
        isFalse,
        reason:
            'a relevant change inside a merge must still refresh attendance',
      );
      events.add(const PosLiveEvent.fallback());
      await tester.pump();
      expect(
        identical(tester.state(find.byType(AttendanceTab)), refreshed),
        isFalse,
        reason: 'the explicit full reconciliation signal remains supported',
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await events.close();
      expect(
        preserved,
        isTrue,
        reason: 'neither orders nor payments changes attendance input state',
      );
    },
  );
}
