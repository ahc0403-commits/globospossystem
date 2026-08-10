import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_control_panel.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _FixtureEmergencyNotifier extends EmergencyFulfillmentNotifier {
  _FixtureEmergencyNotifier(EmergencyFulfillmentState initialState) {
    state = initialState;
  }

  final List<(String, String, int)> recordedProgress = [];

  @override
  Future<void> load({bool showLoading = true}) async {}

  @override
  Future<void> recordProgress({
    required String itemId,
    required String stage,
    int delta = 1,
  }) async {
    recordedProgress.add((itemId, stage, delta));
  }
}

class _FixtureAuthNotifier extends AuthNotifier {
  _FixtureAuthNotifier() : super() {
    state = const PosAuthState(
      role: 'emergency_station',
      storeId: 'store-bt',
      primaryStoreId: 'store-bt',
      accessibleStores: [
        AccessibleStore(id: 'store-bt', name: 'BunsikClub Binh Thanh'),
      ],
    );
  }

  @override
  Future<void> logout() async {}
}

class _FixtureEmergencyControlNotifier extends EmergencyControlNotifier {
  _FixtureEmergencyControlNotifier() {
    state = const EmergencyControlState(
      stores: [
        EmergencyStoreStatus(
          restaurantId: 'store-bt',
          restaurantName: 'BunsikClub Binh Thanh',
          active: false,
          unresolvedQuantity: 0,
          orderCount: 0,
        ),
      ],
    );
  }

  final List<(String, bool, String)> changes = [];

  @override
  Future<void> load() async {}

  @override
  Future<bool> setMode({
    required String storeId,
    required bool enabled,
    required String reason,
    String resolution = 'digital_completed',
    bool force = false,
  }) async {
    changes.add((storeId, enabled, reason));
    return true;
  }
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Supabase.initialize(
      url: 'https://example.supabase.co',
      anonKey: 'test-anon-key',
    );
  });

  testWidgets('tray workflow stays usable on a 390px Vietnamese web screen', (
    tester,
  ) async {
    final fixture = _FixtureEmergencyNotifier(_activeState('tray'));
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(390, 844),
      locale: const Locale('vi'),
    );

    expect(find.byKey(const Key('emergency_fulfillment_screen')), findsOne);
    expect(find.byKey(const Key('emergency_order_order-1')), findsOne);
    expect(find.text('Bánh gạo cay'), findsOne);
    expect(find.text('떡볶이'), findsNothing);
    expect(find.text('Đã nhận từ bếp 0/2'), findsOne);
    expect(find.text('Đã chuyển lên tầng 0/0'), findsOne);
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Đã nhận từ bếp 0/2'));
    await tester.pump();
    expect(fixture.recordedProgress, [('item-1', 'tray_received', 1)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'kitchen uses the tablet split layout with actionable order data',
    (tester) async {
      final fixture = _FixtureEmergencyNotifier(_activeState('kitchen'));
      await _pumpEmergency(
        tester,
        fixture: fixture,
        size: const Size(1024, 768),
        locale: const Locale('ko'),
        expectedStationType: 'kitchen',
      );

      expect(find.text('#101'), findsOne);
      expect(find.text('떡볶이'), findsOne);
      expect(find.text('Bánh gạo cay'), findsNothing);
      expect(find.text('조리 완료 0/2'), findsOne);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('floor workflow has no G-floor surface and renders on mobile', (
    tester,
  ) async {
    final fixture = _FixtureEmergencyNotifier(_activeState('floor'));
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(390, 844),
      locale: const Locale('ko'),
    );

    expect(find.text('2F 주문확인'), findsOne);
    expect(find.text('제공 완료 0/1'), findsOne);
    expect(find.textContaining('G층'), findsNothing);
    expect(find.textContaining('GF'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Super Admin emergency dialog requires and submits a reason', (
    tester,
  ) async {
    final fixture = _FixtureEmergencyControlNotifier();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(390, 844);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.view.resetPhysicalSize);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [emergencyControlProvider.overrideWith((ref) => fixture)],
        child: MaterialApp(
          theme: AppTheme.build(),
          locale: const Locale('ko'),
          supportedLocales: AppLocalizations.supportedLocales,
          localizationsDelegates: const [
            AppLocalizations.delegate,
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          home: const Scaffold(body: EmergencyControlPanel()),
        ),
      ),
    );
    await tester.pump();

    await tester.tap(find.byKey(const Key('emergency_toggle_store-bt')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('emergency_mode_reason')), findsOne);
    expect(find.byKey(const Key('emergency_mode_confirm')), findsOne);

    await tester.enterText(
      find.byKey(const Key('emergency_mode_reason')),
      '프린터 장애',
    );
    await tester.tap(find.byKey(const Key('emergency_mode_confirm')));
    await tester.pumpAndSettle();
    expect(fixture.changes, [('store-bt', true, '프린터 장애')]);
    expect(tester.takeException(), isNull);
  });
}

EmergencyFulfillmentState _activeState(String stationType) =>
    EmergencyFulfillmentState(
      assigned: true,
      active: true,
      restaurantId: 'store-bt',
      sessionId: 'session-1',
      stationType: stationType,
      floorLabel: stationType == 'floor' ? '2F' : null,
      orders: [
        EmergencyFulfillmentOrder(
          queueId: 'queue-1',
          orderId: 'order-1',
          queueNo: 101,
          tableNumber: 'T12',
          floorLabel: '2F',
          createdAt: DateTime.utc(2026, 8, 10, 10),
          items: [
            EmergencyFulfillmentItem(
              id: 'item-1',
              orderItemId: 'order-item-1',
              nameKo: '떡볶이',
              nameVi: 'Bánh gạo cay',
              nameEn: 'Spicy rice cake',
              orderedQuantity: 2,
              kitchenDoneQuantity: stationType == 'kitchen' ? 0 : 2,
              trayReceivedQuantity: stationType == 'floor' ? 2 : 0,
              trayDispatchedQuantity: stationType == 'floor' ? 1 : 0,
              floorServedQuantity: 0,
              needsReview: false,
            ),
          ],
        ),
      ],
    );

Future<void> _pumpEmergency(
  WidgetTester tester, {
  required _FixtureEmergencyNotifier fixture,
  required Size size,
  required Locale locale,
  String? expectedStationType,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  final router = GoRouter(
    initialLocation: '/emergency',
    routes: [
      GoRoute(
        path: '/emergency',
        builder: (context, state) => EmergencyFulfillmentScreen(
          expectedStationType: expectedStationType,
        ),
      ),
      GoRoute(
        path: '/change-password',
        builder: (context, state) => const SizedBox.shrink(),
      ),
    ],
  );
  addTearDown(router.dispose);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _FixtureAuthNotifier()),
        connectivityProvider.overrideWith((ref) => Stream.value(true)),
        emergencyFulfillmentProvider.overrideWith((ref) => fixture),
      ],
      child: MaterialApp.router(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(),
        locale: locale,
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
  await tester.pump(const Duration(milliseconds: 250));
}
