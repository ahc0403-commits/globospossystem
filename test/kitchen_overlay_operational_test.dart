import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/kitchen/kitchen_provider.dart';
import 'package:globos_pos_system/features/kitchen/kitchen_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '7f6c9d22-6d84-4c7f-b923-79c81c4015d1';

class _AuthNotifier extends AuthNotifier {
  _AuthNotifier() : super() {
    state = const PosAuthState(
      role: 'kitchen',
      storeId: _storeId,
      primaryStoreId: _storeId,
      accessibleStores: [
        AccessibleStore(id: _storeId, name: 'GLOBOS Nguyễn Huệ'),
      ],
    );
  }
}

class _KitchenNotifier extends KitchenNotifier {
  _KitchenNotifier() {
    state = const KitchenState();
  }

  @override
  Future<void> loadOrders(String storeId, {bool showLoading = true}) async {}
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

  testWidgets('Kitchen failed-print dialog executes from the top-bar control', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 900);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    final router = GoRouter(
      initialLocation: '/kitchen',
      routes: [
        GoRoute(path: '/kitchen', builder: (_, __) => const KitchenScreen()),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _AuthNotifier()),
          kitchenProvider.overrideWith((ref) => _KitchenNotifier()),
          connectivityProvider.overrideWith((ref) => Stream.value(true)),
          kitchenRestaurantNameProvider.overrideWith(
            (ref, storeId) async => 'GLOBOS Nguyễn Huệ',
          ),
          failedPrintJobsProvider.overrideWith(
            (ref, storeId) async => [
              FailedPrintJob(
                id: 'print-job-failed-1',
                copyType: 'kitchen',
                batchNo: 1,
                tableNumber: 'A1',
                floorLabel: 'Ground',
                status: 'failed',
                updatedAt: DateTime(2026, 7, 18, 12),
                lastError: 'Printer offline',
              ),
            ],
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
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('kitchen_failed_print_jobs_button')));
    await tester.pumpAndSettle();
    final dialog = find.byKey(const Key('kitchen_failed_print_jobs_dialog'));
    expect(dialog, findsOneWidget);
    Navigator.of(tester.element(dialog)).pop();
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
  });
}
