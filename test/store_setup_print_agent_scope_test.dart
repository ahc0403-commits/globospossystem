import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/company_tax_lookup_service.dart';
import 'package:globos_pos_system/core/hardware/print_agent_coordinator.dart';
import 'package:globos_pos_system/core/hardware/print_agent_coordinator_provider.dart';
import 'package:globos_pos_system/core/hardware/print_job_agent_service.dart';
import 'package:globos_pos_system/core/hardware/print_station_mode.dart';
import 'package:globos_pos_system/core/hardware/printer_service.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_models.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_provider.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_screen.dart';
import 'package:globos_pos_system/features/store_setup/store_setup_service.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  testWidgets('opening setup selects its store for the app-root agent', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.open(tester);
    expect(harness.auth.state.storeId, 'store-b');
    expect(harness.driver.startedStores.last, 'store-b');
    expect(
      harness.container.read(printAgentCoordinatorProvider).activeStoreId,
      'store-b',
    );
    expect(harness.runButton(tester).onPressed, isNotNull);

    await harness.run(tester);
    expect(harness.backend.enqueuedStores, ['store-b']);
    await harness.close(tester);
  });

  testWidgets('super admin without an active store can start the setup agent', (
    tester,
  ) async {
    final harness = _Harness(activeStore: null);
    await harness.open(tester);
    expect(harness.driver.startedStores, ['store-b']);
    expect(harness.runButton(tester).onPressed, isNotNull);
    await harness.close(tester);
  });

  testWidgets('disabled agent blocks enqueue and shows why', (tester) async {
    final harness = _Harness(enabled: false);
    await harness.open(tester);
    expect(harness.driver.startedStores, isEmpty);
    expect(harness.runButton(tester).onPressed, isNull);
    expect(
      find.textContaining('Print agent is not processing jobs.'),
      findsWidgets,
    );
    expect(harness.backend.enqueuedStores, isEmpty);
    tester
        .widget<SwitchListTile>(
          find.byKey(const Key('store_setup_print_agent_toggle')),
        )
        .onChanged!(true);
    await tester.pumpAndSettle();
    expect(harness.driver.startedStores, ['store-b']);
    expect(harness.runButton(tester).onPressed, isNotNull);
    await harness.close(tester);
  });

  testWidgets(
    'an agent running for another store does not enable setup tests',
    (tester) async {
      final harness = _Harness(
        accessibleStores: const ['store-a'],
        role: 'store_admin',
      );
      await harness.open(tester);
      expect(harness.auth.state.storeId, 'store-a');
      expect(harness.driver.startedStores, ['store-a']);
      expect(harness.runButton(tester).onPressed, isNull);
      expect(harness.backend.enqueuedStores, isEmpty);
      await harness.close(tester);
    },
  );

  testWidgets('start failure blocks queued tests', (tester) async {
    final harness = _Harness(failStart: true);
    await harness.open(tester);
    expect(
      harness.container.read(printAgentCoordinatorProvider).status,
      PrintAgentStatus.degraded,
    );
    expect(harness.runButton(tester).onPressed, isNull);
    await harness.close(tester);
  });

  testWidgets('changing the setup store switches the single agent scope', (
    tester,
  ) async {
    final harness = _Harness();
    await harness.open(tester);
    await tester.pumpWidget(harness.app('store-c'));
    await tester.pumpAndSettle();
    expect(harness.auth.state.storeId, 'store-c');
    expect(harness.driver.startedStores.last, 'store-c');
    expect(
      harness.container.read(printAgentCoordinatorProvider).activeStoreId,
      'store-c',
    );
    await harness.close(tester);
  });

  testWidgets('Super Admin setup resolves a store omitted from login claims', (
    tester,
  ) async {
    final harness = _Harness(accessibleStores: const ['store-a']);
    await harness.open(tester);
    expect(harness.auth.state.storeId, 'store-b');
    expect(harness.driver.startedStores.last, 'store-b');
    expect(harness.runButton(tester).onPressed, isNotNull);
    await harness.close(tester);
  });

  testWidgets('web setup can still queue tests for a separate native station', (
    tester,
  ) async {
    final harness = _Harness(supported: false);
    await harness.open(tester);
    expect(harness.driver.startedStores, isEmpty);
    expect(harness.runButton(tester).onPressed, isNotNull);
    await harness.run(tester);
    expect(harness.backend.enqueuedStores, ['store-b']);
    await harness.close(tester);
  });
}

class _Harness {
  _Harness({
    String? activeStore = 'store-a',
    bool enabled = true,
    bool failStart = false,
    bool supported = true,
    String role = 'super_admin',
    List<String> accessibleStores = const ['store-a', 'store-b', 'store-c'],
  }) {
    auth = _Auth(activeStore, accessibleStores, role);
    driver = _Driver(failStart: failStart, supported: supported);
    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith((_) => auth),
        printAgentDriverProvider.overrideWithValue(driver),
        printAgentPreferenceStoreProvider.overrideWithValue(
          _Preferences(enabled),
        ),
        storeSetupBackendProvider.overrideWithValue(backend),
      ],
    );
  }

  late final _Auth auth;
  late final _Driver driver;
  late final ProviderContainer container;
  final backend = _Backend();
  final companyLookup = CompanyTaxLookupService(
    transport: (_, _) async => {'outcome': 'unavailable'},
    statusTransport: (_) async => {
      'outcome': 'disabled',
      'configured': false,
      'can_manage': true,
    },
    sessionScope: () => 'fixture',
  );

  Widget app(String storeId) => UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: StoreSetupScreen(
        storeId: storeId,
        companyLookupService: companyLookup,
      ),
    ),
  );

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(app('store-b'));
    await tester.pumpAndSettle();
    final setup = container.read(storeSetupProvider('store-b').notifier);
    expect(await setup.apply(), isTrue);
    setup.goToStep(5);
    await tester.pumpAndSettle();
  }

  FilledButton runButton(WidgetTester tester) => tester.widget<FilledButton>(
    find.byKey(const Key('store_setup_run_five_tests')),
  );

  Future<void> run(WidgetTester tester) async {
    runButton(tester).onPressed!();
    await tester.pumpAndSettle();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    companyLookup.dispose();
    container.dispose();
    await tester.pump();
  }
}

class _Auth extends StateNotifier<PosAuthState> implements AuthNotifier {
  _Auth(String? storeId, List<String> stores, String role)
    : super(
        PosAuthState(
          user: User(
            id: 'setup-user',
            appMetadata: const {},
            userMetadata: const {},
            aud: 'authenticated',
            createdAt: '2026-10-19',
          ),
          role: role,
          storeId: storeId,
          accessibleStores: [
            for (final id in stores) AccessibleStore(id: id, name: id),
          ],
        ),
      );

  @override
  Future<void> setActiveStoreForSetup(String storeId) =>
      setActiveStore(storeId, resolveSuperAdminStore: true);

  @override
  Future<void> setActiveStore(
    String storeId, {
    bool resolveSuperAdminStore = false,
  }) async {
    if (state.accessibleStores.any((store) => store.id == storeId) ||
        (resolveSuperAdminStore && state.role == 'super_admin')) {
      state = state.copyWith(storeId: storeId);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Preferences implements PrintAgentPreferenceStore {
  _Preferences(this.enabled);
  bool enabled;
  @override
  Future<PrintStationMode?> readMode() async => PrintStationMode.printer;
  @override
  Future<void> writeMode(PrintStationMode value) async {}
  @override
  Future<bool> readEnabled() async => enabled;
  @override
  Future<void> writeEnabled(bool value) async => enabled = value;
}

class _Driver implements PrintAgentDriver {
  _Driver({required this.failStart, required this.supported});
  final bool failStart;
  final bool supported;
  final startedStores = <String>[];
  @override
  bool get isSupported => supported;
  @override
  Future<void> configureReceiptOnly(bool receiptOnly) async {}
  @override
  Future<void> startPollingSafely(
    String storeId, {
    bool receiptOnly = false,
  }) async {
    if (failStart) throw StateError('start failed');
    startedStores.add(storeId);
  }

  @override
  Future<void> stopSafely() async {}
  @override
  Future<List<PrintJobAgentResult>> processOnce(
    String storeId, {
    int limit = 10,
  }) async => [];
  @override
  Future<PrintResult> testPrintDestination(String destinationId) async =>
      PrintResult.success;
}

class _Backend implements StoreSetupBackend {
  final enqueuedStores = <String>[];
  @override
  Future<StoreSetupExistingConfig> loadExisting(String storeId) async =>
      StoreSetupExistingConfig(
        store: {'id': storeId, 'name': storeId, 'is_active': true},
        tables: const [],
        destinations: [
          {
            'id': 'receipt-$storeId',
            'purpose': 'receipt',
            'name': 'Cashier',
            'is_active': true,
          },
        ],
        operation: StorePrinterOperation.paperless,
      );
  @override
  Future<StoreSetupValidationResult> validate(StoreOpeningDraft draft) async =>
      const StoreSetupValidationResult(valid: true);
  @override
  Future<Map<String, dynamic>> apply(StoreOpeningDraft draft) async => {};
  @override
  Future<Map<String, dynamic>> readiness(String storeId) async => {};
  @override
  Future<Map<String, dynamic>> workforceReadiness(String storeId) async => {};
  @override
  Future<List<StoreSetupTestJob>> enqueueTests({
    required String storeId,
    required Map<String, LogicalDestinationDraft> destinationsById,
  }) async {
    enqueuedStores.add(storeId);
    return [
      for (final entry in destinationsById.entries)
        StoreSetupTestJob(
          label: entry.value.label,
          destinationId: entry.key,
          jobId: 'test-job',
        ),
    ];
  }

  @override
  Future<Map<String, Map<String, dynamic>>> fetchTestJobs(
    String storeId,
    Iterable<String> jobIds,
  ) async => {};
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
