import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/live_refresh_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/admin/providers/admin_scope_provider.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/inventory/inventory_provider.dart';
import 'package:globos_pos_system/features/inventory_purchase/inventory_purchase_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Auth extends AuthNotifier {
  _Auth() {
    state = const PosAuthState(role: 'super_admin', storeId: 'store-a');
  }
}

class _Overview extends InventoryPurchaseOverviewNotifier {
  @override
  Future<void> load(String storeId) async {}
}

class _Stock extends InventoryPurchaseStockStatusNotifier {
  @override
  Future<void> load(String storeId, {DateTime? asOfDate}) async {}
}

class _Snapshot extends InventoryPurchaseRecommendationSnapshotNotifier {
  final pending = Completer<void>();
  final calls = <String>[];

  @override
  Future<void> loadLatest(String storeId) async {
    calls.add(storeId);
    if (storeId == 'store-a') await pending.future;
  }
}

class _Orders extends InventoryPurchaseOrderSummaryNotifier {
  final calls = <String>[];

  @override
  Future<void> load(String storeId) async => calls.add(storeId);
}

class _Harness {
  _Harness(this.container, this.selectedStore, this.snapshot, this.orders);

  final ProviderContainer container;
  final StateProvider<String> selectedStore;
  final _Snapshot snapshot;
  final _Orders orders;
}

Future<_Harness> _mount(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1600, 1100);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final selectedStore = StateProvider((ref) => 'store-a');
  final snapshot = _Snapshot();
  final orders = _Orders();
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith((ref) => _Auth()),
      adminScopedStoreIdProvider.overrideWith(
        (ref) => ref.watch(selectedStore),
      ),
      inventoryPurchaseOverviewProvider.overrideWith((ref) => _Overview()),
      inventoryPurchaseStockStatusProvider.overrideWith((ref) => _Stock()),
      inventoryPurchaseRecommendationSnapshotProvider.overrideWith(
        (ref) => snapshot,
      ),
      inventoryPurchaseOrderSummaryProvider.overrideWith((ref) => orders),
      for (final store in ['store-a', 'store-b'])
        posLiveEventsProvider(
          store,
        ).overrideWith((ref) => const Stream<PosLiveEvent>.empty()),
    ],
  );
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.build(),
        locale: const Locale('en'),
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: InventoryPurchaseScreen()),
      ),
    ),
  );
  await tester.pump();
  expect(snapshot.calls, ['store-a']);
  return _Harness(container, selectedStore, snapshot, orders);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://inventory-reload-fixture.supabase.co',
      anonKey: 'fixture',
      authOptions: const FlutterAuthClientOptions(autoRefreshToken: false),
    );
  });
  tearDownAll(() => Supabase.instance.dispose());

  testWidgets('leaving inventory during a read stops the reload chain', (
    tester,
  ) async {
    final h = await _mount(tester);
    await tester.pumpWidget(const SizedBox.shrink());
    h.snapshot.pending.complete();
    await tester.pump();
    expect(h.orders.calls, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('an old store read cannot start follow-up requests', (
    tester,
  ) async {
    final h = await _mount(tester);
    h.container.read(h.selectedStore.notifier).state = 'store-b';
    await tester.pump();
    await tester.pump();
    expect(h.snapshot.calls, ['store-a', 'store-b']);
    expect(h.orders.calls, ['store-b']);
    h.snapshot.pending.complete();
    await tester.pump();
    expect(h.orders.calls, ['store-b']);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('changing sections cancels the old section reload chain', (
    tester,
  ) async {
    final h = await _mount(tester);
    await tester.tap(find.byKey(const Key('inventory_section_1')));
    await tester.pump();
    h.snapshot.pending.complete();
    await tester.pump();
    expect(h.orders.calls, isEmpty);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
