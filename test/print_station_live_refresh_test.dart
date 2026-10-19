import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';
import 'package:globos_pos_system/core/services/printer_destination_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/admin/providers/printer_destinations_provider.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/kitchen/kitchen_provider.dart';
import 'package:globos_pos_system/features/print_station/print_station_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _store = '00000000-0000-0000-0000-000000000001';
const _destinations = [
  PrinterDestinationConfig(
    id: 'receipt',
    storeId: _store,
    name: 'Cashier fixture',
    ip: '192.0.2.1',
    port: 9100,
    purpose: 'receipt',
    isActive: true,
  ),
];

class _Auth extends AuthNotifier {
  _Auth() {
    state = const PosAuthState(role: 'store_admin', storeId: _store);
  }
}

class _Printers extends PrinterDestinationService {
  int calls = 0;
  Completer<List<PrinterDestinationConfig>>? gate;
  @override
  Future<List<PrinterDestinationConfig>> fetchDestinations(String storeId) {
    calls++;
    return gate?.future ?? Future.value(_destinations);
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    SharedPreferences.setMockInitialValues({
      'print_station_mode_v1': 'printer',
    });
    await Supabase.initialize(
      url: 'http://localhost:54321',
      anonKey: 'fixture',
    );
  });

  testWidgets(
    'orders/jobs retain printer cards; configuration/recovery refresh in place once',
    (tester) async {
      tester.view.physicalSize = const Size(1280, 1000);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final events = StreamController<PosLiveEvent>();
      final service = _Printers();
      var creations = 0;
      final router = GoRouter(
        initialLocation: '/',
        routes: [
          GoRoute(
            path: '/',
            builder: (_, __) =>
                const PrintStationScreen(isSupportedOverride: true),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith((ref) => _Auth()),
            posLiveEventsProvider(_store).overrideWith((ref) => events.stream),
            serviceConnectivityProvider.overrideWith(
              (ref) => Stream.value(
                const ServiceConnectivityState(
                  kind: ServiceConnectivityKind.online,
                ),
              ),
            ),
            printerDestinationsProvider(_store).overrideWith((ref) {
              creations++;
              return PrinterDestinationsNotifier(_store, service: service);
            }),
            printStationJobsProvider(
              _store,
            ).overrideWith((ref) async => const <FailedPrintJob>[]),
            failedPrintJobsProvider(
              _store,
            ).overrideWith((ref) async => const <FailedPrintJob>[]),
          ],
          child: MaterialApp.router(
            theme: AppTheme.build(),
            locale: const Locale('en'),
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
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Cashier fixture'), findsOneWidget);
      expect(service.calls, 1);
      for (final event in [
        const PosLiveEvent(
          domain: 'print',
          sourceTable: 'print_jobs',
          eventType: 'UPDATE',
        ),
        const PosLiveEvent(
          domain: 'orders',
          sourceTable: 'order_items',
          eventType: 'INSERT',
        ),
      ]) {
        events.add(event);
        await tester.pump();
        await tester.pump();
        expect(find.text('Cashier fixture'), findsOneWidget);
      }
      expect(service.calls, 1);
      service.gate = Completer<List<PrinterDestinationConfig>>();
      events.add(const PosLiveEvent.fallback());
      await tester.pump();
      await tester.pump();
      expect(service.calls, 2);
      expect(find.text('Cashier fixture'), findsOneWidget);
      // A concurrent configuration signal joins the outstanding request.
      events.add(
        const PosLiveEvent(
          domain: 'print',
          sourceTable: 'printer_destinations',
          eventType: 'UPDATE',
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(service.calls, 2);
      expect(creations, 1);
      expect(find.text('Cashier fixture'), findsOneWidget);
      service.gate!.completeError(StateError('fixture transient failure'));
      await tester.pump();
      await tester.pump();
      expect(find.text('Cashier fixture'), findsOneWidget);
      service.gate = null;
      events.add(
        const PosLiveEvent(
          domain: 'print',
          sourceTable: 'printer_endpoints',
          eventType: 'UPDATE',
        ).merge(
          const PosLiveEvent(
            domain: 'orders',
            sourceTable: 'order_items',
            eventType: 'INSERT',
          ),
        ),
      );
      await tester.pump();
      await tester.pump();
      expect(service.calls, 3);
      expect(creations, 1);
      expect(find.text('Cashier fixture'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      unawaited(events.close());
    },
  );
}
