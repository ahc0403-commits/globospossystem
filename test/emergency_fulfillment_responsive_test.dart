import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/connectivity_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/core/ui/pos_design_tokens.dart';
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
  final List<String> completedQueues = [];
  final List<(String, String)> revertedActions = [];

  @override
  Future<void> load({bool showLoading = true}) async {}

  @override
  Future<void> recordProgress({
    required String itemId,
    required String stage,
    int delta = 1,
  }) async {
    recordedProgress.add((itemId, stage, delta));
    state = state.copyWith(
      orders: state.orders
          .map(
            (order) => order.copyWith(
              items: order.items
                  .map(
                    (item) => item.id == itemId
                        ? item.withStage(
                            stage,
                            (item.quantityForStage(stage) + delta).clamp(
                              0,
                              item.orderedQuantity,
                            ),
                          )
                        : item,
                  )
                  .toList(growable: false),
            ),
          )
          .toList(growable: false),
    );
  }

  @override
  Future<bool> completeOrder({required String queueId}) async {
    completedQueues.add(queueId);
    final stationType = state.stationType;
    state = state.copyWith(
      orders: state.orders
          .map((order) {
            if (order.queueId != queueId) return order;
            return order.copyWith(
              items: order.items
                  .map(
                    (item) => switch (stationType) {
                      'kitchen' => item.withStage(
                        'kitchen_done',
                        item.orderedQuantity,
                      ),
                      'tray' =>
                        item
                            .withStage(
                              'tray_received',
                              item.kitchenDoneQuantity,
                            )
                            .withStage(
                              'tray_dispatched',
                              item.kitchenDoneQuantity,
                            ),
                      'floor' => item.withStage(
                        'floor_served',
                        item.isFloorDirect
                            ? item.orderedQuantity
                            : item.trayDispatchedQuantity,
                      ),
                      _ => item,
                    },
                  )
                  .toList(growable: false),
            );
          })
          .toList(growable: false),
    );
    return true;
  }

  @override
  Future<bool> revertOrder({
    required String queueId,
    required String actionId,
  }) async {
    revertedActions.add((queueId, actionId));
    return true;
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
  final List<(String, bool, String)> floorDirectChanges = [];

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

  @override
  Future<bool> setFloorDirectBeverages({
    required String storeId,
    required bool enabled,
    required String reason,
  }) async {
    floorDirectChanges.add((storeId, enabled, reason));
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

  testWidgets('phone uses four slots and opens the tray order detail', (
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
    expect(find.byKey(const Key('emergency_order_grid_4_slots')), findsOne);
    expect(
      find.byWidgetPredicate(
        (widget) =>
            widget.key is Key &&
            widget.key.toString().contains('emergency_empty_slot_'),
      ),
      findsNWidgets(3),
    );
    expect(find.byKey(const Key('emergency_order_order-1')), findsOne);
    expect(find.text('Bánh gạo cay'), findsOne);

    await tester.tap(find.byKey(const Key('emergency_order_order-1')));
    await tester.pump();
    expect(find.text('Bánh gạo cay'), findsOne);
    expect(find.text('떡볶이'), findsNothing);
    expect(find.text('0 / 2'), findsOne);
    expect(find.byKey(const Key('emergency_complete_order')), findsNothing);
    expect(tester.takeException(), isNull);

    await tester.tap(find.byKey(const Key('emergency_menu_item_item-1')));
    await tester.pumpAndSettle();
    expect(fixture.recordedProgress, [
      ('item-1', 'tray_received', 1),
      ('item-1', 'tray_dispatched', 1),
    ]);

    expect(fixture.completedQueues, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tablet uses eight slots and opens all kitchen menu data', (
    tester,
  ) async {
    final fixture = _FixtureEmergencyNotifier(_activeState('kitchen'));
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(1024, 768),
      locale: const Locale('ko'),
      expectedStationType: 'kitchen',
    );

    expect(find.byKey(const Key('emergency_order_grid_8_slots')), findsOne);
    expect(find.text('#101'), findsOne);
    expect(find.text('Bánh gạo cay'), findsOne);

    await tester.tap(find.byKey(const Key('emergency_order_order-1')));
    await tester.pump();
    expect(find.text('Bánh gạo cay'), findsOne);
    expect(find.text('떡볶이'), findsNothing);
    expect(find.text('0 / 2'), findsOne);
    await tester.tap(find.byKey(const Key('emergency_menu_item_item-1')));
    await tester.pumpAndSettle();
    expect(fixture.recordedProgress, [('item-1', 'kitchen_done', 1)]);
    expect(tester.takeException(), isNull);
  });

  for (final stationType in ['kitchen', 'tray', 'floor']) {
    testWidgets(
      '$stationType renders combo components as separate menu cards in detail',
      (tester) async {
        final fixture = _FixtureEmergencyNotifier(_comboState(stationType));
        await _pumpEmergency(
          tester,
          fixture: fixture,
          size: const Size(1024, 768),
          locale: const Locale('vi'),
          expectedStationType: stationType,
        );

        await tester.tap(find.byKey(const Key('emergency_order_order-combo')));
        await tester.pump();

        expect(
          find.byKey(
            const ValueKey('emergency_menu_item_combo-parent:combo:food-1'),
          ),
          findsOne,
        );
        expect(
          find.byKey(
            const ValueKey('emergency_menu_item_combo-parent:combo:food-2'),
          ),
          findsOne,
        );
        expect(find.text('Tteokbokki Truyền Thống'), findsOne);
        expect(find.text('Kimbap Cá Ngừ'), findsOne);
        expect(find.text('Combo A'), findsNothing);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'one combo component completes independently and moves behind pending food',
    (tester) async {
      final fixture = _FixtureEmergencyNotifier(_comboState('kitchen'));
      await _pumpEmergency(
        tester,
        fixture: fixture,
        size: const Size(1024, 768),
        locale: const Locale('vi'),
        expectedStationType: 'kitchen',
      );

      await tester.tap(find.byKey(const Key('emergency_order_order-combo')));
      await tester.pump();
      const firstKey = ValueKey(
        'emergency_menu_item_combo-parent:combo:food-1',
      );
      const secondKey = ValueKey(
        'emergency_menu_item_combo-parent:combo:food-2',
      );

      await tester.tap(find.byKey(firstKey));
      await tester.pump();

      expect(fixture.recordedProgress, [('combo-food-1', 'kitchen_done', 1)]);
      expect(find.text('1 / 1'), findsOne);
      expect(find.text('0 / 1'), findsOne);
      expect(
        tester.getTopLeft(find.byKey(secondKey)).dy,
        lessThan(tester.getTopLeft(find.byKey(firstKey)).dy),
      );

      await tester.tap(
        find.byKey(
          const ValueKey(
            'emergency_menu_item_cancel_combo-parent:combo:food-1',
          ),
        ),
      );
      await tester.pump();

      expect(fixture.recordedProgress, [
        ('combo-food-1', 'kitchen_done', 1),
        ('combo-food-1', 'kitchen_done', -1),
      ]);
      expect(find.text('0 / 1'), findsNWidgets(2));
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('detail home button returns to the order board', (tester) async {
    final fixture = _FixtureEmergencyNotifier(_activeState('kitchen'));
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(1024, 768),
      locale: const Locale('ko'),
    );

    await tester.tap(find.byKey(const Key('emergency_order_order-1')));
    await tester.pump();
    expect(find.byKey(const Key('emergency_order_detail_order-1')), findsOne);

    expect(find.byKey(const Key('emergency_detail_home')), findsOne);
    await tester.tap(find.byKey(const Key('emergency_detail_home')));
    await tester.pump();
    expect(
      find.byKey(const Key('emergency_order_detail_order-1')),
      findsNothing,
    );
    expect(find.byKey(const Key('emergency_order_grid_8_slots')), findsOne);
  });

  testWidgets('finishing every item automatically returns home', (
    tester,
  ) async {
    final fixture = _FixtureEmergencyNotifier(_activeState('kitchen'));
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(1024, 768),
      locale: const Locale('ko'),
    );

    await tester.tap(find.byKey(const Key('emergency_order_order-1')));
    await tester.pump();
    final completeItem = find.byKey(
      const Key('emergency_menu_item_complete_item-1'),
    );
    await tester.tap(completeItem);
    await tester.pump();
    expect(find.byKey(const Key('emergency_order_detail_order-1')), findsOne);

    await tester.tap(completeItem);
    await tester.pump();
    expect(
      find.byKey(const Key('emergency_order_detail_order-1')),
      findsNothing,
    );
    expect(find.byKey(const Key('emergency_board_mode_selector')), findsOne);
    expect(find.text('대기 주문 없음'), findsOne);
  });

  testWidgets('order detail omits the whole-order completion button', (
    tester,
  ) async {
    final fixture = _FixtureEmergencyNotifier(
      _activeState('kitchen', orderCount: 2),
    );
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(1024, 768),
      locale: const Locale('ko'),
    );

    await tester.tap(find.byKey(const Key('emergency_order_order-1')));
    await tester.pump();
    expect(find.byKey(const Key('emergency_complete_order')), findsNothing);
    expect(find.text('완료 후 홈으로'), findsNothing);
    expect(find.byKey(const Key('emergency_detail_home')), findsOne);
  });

  testWidgets(
    'tablet detail shows ten menu items in five columns and two rows',
    (tester) async {
      final fixture = _FixtureEmergencyNotifier(
        _activeStateWithMenuItems('kitchen', 10),
      );
      await _pumpEmergency(
        tester,
        fixture: fixture,
        size: const Size(1024, 768),
        locale: const Locale('ko'),
        expectedStationType: 'kitchen',
      );

      await tester.tap(find.byKey(const Key('emergency_order_order-1')));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const Key('emergency_detail_menu_grid_5_columns')),
        findsOne,
      );
      final itemFinders = List.generate(
        10,
        (index) => find.byKey(Key('emergency_menu_item_menu-${index + 1}')),
      );
      for (final finder in itemFinders) {
        expect(finder, findsOne);
      }
      final firstRowY = tester.getCenter(itemFinders.first).dy;
      for (final finder in itemFinders.take(5)) {
        expect(tester.getCenter(finder).dy, closeTo(firstRowY, 0.1));
      }
      expect(tester.getCenter(itemFinders[5]).dy, greaterThan(firstRowY));
      expect(
        tester.getCenter(itemFinders[5]).dx,
        closeTo(tester.getCenter(itemFinders.first).dx, 0.1),
      );
      await tester.tap(itemFinders[5]);
      await tester.pumpAndSettle();
      expect(fixture.recordedProgress, [('menu-6', 'kitchen_done', 1)]);
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
    expect(find.text('페이퍼리스 작업 중'), findsOne);
    expect(find.byKey(const Key('emergency_order_grid_4_slots')), findsOne);
    await tester.tap(find.byKey(const Key('emergency_order_order-1')));
    await tester.pump();
    expect(find.text('0 / 1'), findsOne);
    await tester.tap(find.byKey(const Key('emergency_menu_item_item-1')));
    await tester.pumpAndSettle();
    expect(fixture.recordedProgress, [('item-1', 'floor_served', 1)]);
    expect(find.textContaining('G층'), findsNothing);
    expect(find.textContaining('GF'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('floor tablet keeps the three-language selector', (tester) async {
    final fixture = _FixtureEmergencyNotifier(_activeState('floor'));
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(1024, 768),
      locale: const Locale('ko'),
    );

    expect(find.text('2F 주문확인'), findsOne);
    expect(find.text('페이퍼리스 작업 중'), findsOne);
    expect(find.text('KO'), findsOne);

    await tester.tap(find.text('KO'));
    await tester.pumpAndSettle();
    expect(find.text('한국어'), findsOne);
    expect(find.text('영어'), findsOne);
    expect(find.text('베트남어'), findsOne);
  });

  for (final scenario
      in <({String stationType, List<(String, String, int)> expected})>[
        (stationType: 'kitchen', expected: [('item-1', 'kitchen_done', -1)]),
        (
          stationType: 'tray',
          expected: [
            ('item-1', 'tray_dispatched', -1),
            ('item-1', 'tray_received', -1),
          ],
        ),
        (stationType: 'floor', expected: [('item-1', 'floor_served', -1)]),
      ]) {
    testWidgets('${scenario.stationType} can cancel one completed menu item', (
      tester,
    ) async {
      final fixture = _FixtureEmergencyNotifier(
        _revertibleState(scenario.stationType),
      );
      await _pumpEmergency(
        tester,
        fixture: fixture,
        size: const Size(1024, 768),
        locale: const Locale('ko'),
        expectedStationType: scenario.stationType,
      );

      await tester.tap(find.byKey(const Key('emergency_order_order-1')));
      await tester.pump();
      final cancelButton = find.byKey(
        const Key('emergency_menu_item_cancel_item-1'),
      );
      expect(cancelButton, findsOne);
      await tester.tap(cancelButton);
      await tester.pumpAndSettle();

      expect(fixture.recordedProgress, scenario.expected);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('ninth tablet order is placed on the next eight-slot page', (
    tester,
  ) async {
    final fixture = _FixtureEmergencyNotifier(
      _activeState('kitchen', orderCount: 9),
    );
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(1024, 768),
      locale: const Locale('ko'),
    );

    expect(find.byKey(const Key('emergency_order_order-1')), findsOne);
    expect(find.byKey(const Key('emergency_order_order-9')), findsNothing);
    await tester.tap(find.byKey(const Key('emergency_board_next')));
    await tester.pump();
    expect(find.byKey(const Key('emergency_order_order-1')), findsNothing);
    expect(find.byKey(const Key('emergency_order_order-9')), findsOne);
    expect(tester.takeException(), isNull);
  });

  testWidgets('recent completed order exposes cancel and revert', (
    tester,
  ) async {
    final fixture = _FixtureEmergencyNotifier(_completedState('floor'));
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(390, 844),
      locale: const Locale('ko'),
    );

    await tester.tap(find.text('최근 완료 1'));
    await tester.pump();
    expect(find.text('05:00'), findsOne);
    await tester.pump(const Duration(seconds: 3));
    expect(find.text('05:00'), findsOne);
    await tester.tap(find.byKey(const Key('emergency_order_order-1')));
    await tester.pump();
    expect(find.byKey(const Key('emergency_revert_order')), findsOne);
    await tester.tap(find.byKey(const Key('emergency_revert_order')));
    await tester.pump();
    expect(fixture.revertedActions, [('queue-1', 'action-1')]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('today completed history opens orders outside active session', (
    tester,
  ) async {
    final completed = _completedState('floor').orders.single;
    final fixture = _FixtureEmergencyNotifier(
      _activeState(
        'floor',
      ).copyWith(orders: const [], completedOrders: [completed]),
    );
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(390, 844),
      locale: const Locale('ko'),
    );

    await tester.tap(find.text('최근 완료 1'));
    await tester.pump();
    await tester.tap(find.byKey(const Key('emergency_order_order-1')));
    await tester.pump();

    expect(find.byKey(const Key('emergency_order_detail_order-1')), findsOne);
    expect(find.text('Bánh gạo cay'), findsWidgets);
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

  testWidgets('Super Admin floor-direct dialog confirms new-order routing', (
    tester,
  ) async {
    final fixture = _FixtureEmergencyControlNotifier();
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1024, 768);
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

    await tester.tap(find.byKey(const Key('floor_direct_toggle_store-bt')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('floor_direct_reason')), findsOne);
    expect(find.byKey(const Key('floor_direct_confirm')), findsOne);
    expect(find.text('기존 주문 경로는 바뀌지 않으며, 변경 후 생성되는 새 주문부터 적용됩니다.'), findsOne);

    await tester.enterText(
      find.byKey(const Key('floor_direct_reason')),
      '층 음료 운영 시작',
    );
    await tester.tap(find.byKey(const Key('floor_direct_confirm')));
    await tester.pumpAndSettle();
    expect(fixture.floorDirectChanges, [('store-bt', true, '층 음료 운영 시작')]);
    expect(tester.takeException(), isNull);
  });

  for (final stationType in ['kitchen', 'tray']) {
    testWidgets('floor-direct-only order is hidden in $stationType', (
      tester,
    ) async {
      final fixture = _FixtureEmergencyNotifier(_floorDirectState(stationType));
      await _pumpEmergency(
        tester,
        fixture: fixture,
        size: const Size(1024, 768),
        locale: const Locale('ko'),
        expectedStationType: stationType,
      );

      expect(
        find.byKey(const Key('emergency_order_order-direct')),
        findsNothing,
      );
      expect(find.text('콜라'), findsNothing);
      expect(find.text('Coca-Cola'), findsNothing);
      expect(find.text('대기 주문 없음'), findsOne);
      expect(tester.takeException(), isNull);
    });

    testWidgets('mixed order hides its floor drink in $stationType', (
      tester,
    ) async {
      final fixture = _FixtureEmergencyNotifier(_mixedRouteState(stationType));
      await _pumpEmergency(
        tester,
        fixture: fixture,
        size: const Size(1024, 768),
        locale: const Locale('ko'),
        expectedStationType: stationType,
      );

      await tester.tap(find.byKey(const Key('emergency_order_order-mixed')));
      await tester.pump();
      expect(find.text('Bánh gạo cay'), findsOne);
      expect(find.text('콜라'), findsNothing);
      expect(find.text('Coca-Cola'), findsNothing);
      expect(
        find.byKey(const Key('emergency_floor_beverage_section')),
        findsNothing,
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('floor separates direct drinks above kitchen and tray food', (
    tester,
  ) async {
    final fixture = _FixtureEmergencyNotifier(_mixedRouteState('floor'));
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(1024, 768),
      locale: const Locale('ko'),
    );

    await tester.tap(find.byKey(const Key('emergency_order_order-mixed')));
    await tester.pump();
    final beverageSection = find.byKey(
      const Key('emergency_floor_beverage_section'),
    );
    final foodSection = find.byKey(const Key('emergency_floor_food_section'));
    expect(beverageSection, findsOne);
    expect(foodSection, findsOne);
    expect(find.text('먼저 제공할 음료'), findsOne);
    expect(find.text('주방·트레이 음식'), findsOne);
    expect(find.text('Coca-Cola'), findsOne);
    expect(find.text('Bánh gạo cay'), findsOne);
    expect(
      tester.getTopLeft(beverageSection).dy,
      lessThan(tester.getTopLeft(foodSection).dy),
    );

    await tester.tap(find.byKey(const ValueKey('emergency_menu_item_drink-1')));
    await tester.pump();
    expect(fixture.recordedProgress, [('drink-1', 'floor_served', 1)]);

    await tester.tap(find.byKey(const ValueKey('emergency_menu_item_food-1')));
    await tester.pump();
    expect(fixture.recordedProgress, [
      ('drink-1', 'floor_served', 1),
      ('food-1', 'floor_served', 1),
    ]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('floor can undo a directly served drink', (tester) async {
    final fixture = _FixtureEmergencyNotifier(
      _mixedRouteState('floor', directServedQuantity: 1),
    );
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(1024, 768),
      locale: const Locale('ko'),
      expectedStationType: 'floor',
    );

    await tester.tap(find.byKey(const Key('emergency_order_order-mixed')));
    await tester.pump();
    await tester.tap(
      find.byKey(const Key('emergency_menu_item_cancel_drink-1')),
    );
    await tester.pump();
    expect(fixture.recordedProgress, [('drink-1', 'floor_served', -1)]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('card shows menu completion colors and a digital clock', (
    tester,
  ) async {
    final active = _activeState('kitchen');
    final order = active.orders.single;
    final item = order.items.single;
    final fixture = _FixtureEmergencyNotifier(
      active.copyWith(
        orders: [
          order.copyWith(
            items: [
              item.withStage('kitchen_done', item.orderedQuantity),
              const EmergencyFulfillmentItem(
                id: 'item-2',
                orderItemId: 'order-item-2',
                nameKo: '김밥',
                nameVi: 'Cơm cuộn',
                nameEn: 'Gimbap',
                orderedQuantity: 1,
                kitchenDoneQuantity: 0,
                trayReceivedQuantity: 0,
                trayDispatchedQuantity: 0,
                floorServedQuantity: 0,
                needsReview: false,
              ),
            ],
          ),
        ],
      ),
    );
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(1024, 768),
      locale: const Locale('vi'),
      expectedStationType: 'kitchen',
    );

    final completed = tester.widget<Text>(
      find.byKey(const Key('emergency_card_menu_item-1')),
    );
    final pending = tester.widget<Text>(
      find.byKey(const Key('emergency_card_menu_item-2')),
    );
    expect(completed.style?.color, PosColors.success);
    expect(pending.style?.color, PosColors.textPrimary);
    expect(find.byKey(const Key('emergency_order_elapsed_order-1')), findsOne);

    final orderNumber = tester.widget<Text>(
      find.byKey(const Key('emergency_order_number_order-1')),
    );
    final tableNumber = tester.widget<Text>(
      find.byKey(const Key('emergency_order_table_order-1')),
    );
    expect(tableNumber.data, 'T12');
    expect(
      tableNumber.style?.fontSize,
      closeTo((orderNumber.style?.fontSize ?? 0) * 1.4, 0.001),
    );
    expect(find.text('Bàn T12'), findsNothing);
    expect(find.text('2F · 2 món'), findsNothing);
  });

  testWidgets('floor marks every delivered quantity served as green', (
    tester,
  ) async {
    final active = _activeState('floor');
    final order = active.orders.single;
    final item = order.items.single;
    final fixture = _FixtureEmergencyNotifier(
      active.copyWith(
        orders: [
          order.copyWith(
            items: [
              item.withStage('floor_served', item.trayDispatchedQuantity),
            ],
          ),
        ],
      ),
    );
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(1024, 768),
      locale: const Locale('ko'),
      expectedStationType: 'floor',
    );

    final completed = tester.widget<Text>(
      find.byKey(const Key('emergency_card_menu_item-1')),
    );
    expect(item.trayDispatchedQuantity, lessThan(item.orderedQuantity));
    expect(completed.style?.color, PosColors.success);
  });

  for (final stationType in ['tray', 'floor']) {
    testWidgets('$stationType shows previous-stage food in blue with legend', (
      tester,
    ) async {
      final fixture = _FixtureEmergencyNotifier(_activeState(stationType));
      await _pumpEmergency(
        tester,
        fixture: fixture,
        size: const Size(1024, 768),
        locale: const Locale('ko'),
        expectedStationType: stationType,
      );

      final menu = tester.widget<Text>(
        find.byKey(const Key('emergency_card_menu_item-1')),
      );
      expect(menu.style?.color, PosColors.info);
      expect(
        find.byKey(Key('emergency_menu_status_legend_$stationType')),
        findsOne,
      );
      expect(find.text('녹색 - 완료'), findsOne);
      expect(find.text('검은색 - 진행중'), findsOne);
      expect(find.text('파란색 - 전 단계 완료·다음 단계 인계 전'), findsOne);
    });
  }

  testWidgets('kitchen legend omits the previous-stage blue state', (
    tester,
  ) async {
    final fixture = _FixtureEmergencyNotifier(_activeState('kitchen'));
    await _pumpEmergency(
      tester,
      fixture: fixture,
      size: const Size(1024, 768),
      locale: const Locale('ko'),
      expectedStationType: 'kitchen',
    );

    expect(
      find.byKey(const Key('emergency_menu_status_legend_kitchen')),
      findsOne,
    );
    expect(find.text('녹색 - 완료'), findsOne);
    expect(find.text('검은색 - 진행중'), findsOne);
    expect(find.textContaining('파란색 -'), findsNothing);
  });
}

EmergencyFulfillmentState _floorDirectState(String stationType) =>
    EmergencyFulfillmentState(
      assigned: true,
      active: true,
      restaurantId: 'store-bt',
      sessionId: 'session-1',
      stationType: stationType,
      floorLabel: stationType == 'floor' ? '2F' : null,
      orders: [
        EmergencyFulfillmentOrder(
          queueId: 'queue-direct',
          orderId: 'order-direct',
          queueNo: 201,
          tableNumber: 'T20',
          floorLabel: '2F',
          createdAt: DateTime.utc(2026, 8, 12, 10),
          items: const [
            EmergencyFulfillmentItem(
              id: 'drink-1',
              orderItemId: 'order-item-drink-1',
              nameKo: '콜라',
              nameVi: 'Coca-Cola',
              nameEn: 'Cola',
              orderedQuantity: 1,
              kitchenDoneQuantity: 0,
              trayReceivedQuantity: 0,
              trayDispatchedQuantity: 0,
              floorServedQuantity: 0,
              needsReview: false,
              fulfillmentRoute: 'floor_direct',
            ),
          ],
        ),
      ],
    );

EmergencyFulfillmentState _comboState(String stationType) =>
    EmergencyFulfillmentState(
      assigned: true,
      active: true,
      restaurantId: 'store-bt',
      sessionId: 'session-1',
      stationType: stationType,
      orders: [
        EmergencyFulfillmentOrder(
          queueId: 'queue-combo',
          orderId: 'order-combo',
          queueNo: 104,
          tableNumber: '104',
          floorLabel: '1F',
          createdAt: DateTime.utc(2026, 8, 16, 9),
          items: [
            EmergencyFulfillmentItem(
              id: 'combo-parent',
              orderItemId: 'order-item-combo',
              nameKo: '콤보 A',
              nameVi: 'Combo A',
              nameEn: 'Combo A',
              orderedQuantity: 1,
              kitchenDoneQuantity: stationType == 'kitchen' ? 0 : 1,
              trayReceivedQuantity: stationType == 'floor' ? 1 : 0,
              trayDispatchedQuantity: stationType == 'floor' ? 1 : 0,
              floorServedQuantity: 0,
              needsReview: false,
              comboComponents: const [
                EmergencyComboComponent(
                  menuItemId: 'food-1',
                  nameKo: '전통 떡볶이',
                  nameVi: 'Tteokbokki Truyền Thống',
                  nameEn: 'Traditional Tteokbokki',
                  quantity: 1,
                  isTotalQuantity: false,
                  fulfillmentRoute: 'kitchen_tray_floor',
                ),
                EmergencyComboComponent(
                  menuItemId: 'food-2',
                  nameKo: '참치 김밥',
                  nameVi: 'Kimbap Cá Ngừ',
                  nameEn: 'Tuna Kimbap',
                  quantity: 1,
                  isTotalQuantity: false,
                  fulfillmentRoute: 'kitchen_tray_floor',
                ),
              ],
            ),
            EmergencyFulfillmentItem(
              id: 'combo-food-1',
              orderItemId: 'order-item-combo',
              nameKo: '전통 떡볶이',
              nameVi: 'Tteokbokki Truyền Thống',
              nameEn: 'Traditional Tteokbokki',
              orderedQuantity: 1,
              kitchenDoneQuantity: stationType == 'kitchen' ? 0 : 1,
              trayReceivedQuantity: stationType == 'floor' ? 1 : 0,
              trayDispatchedQuantity: stationType == 'floor' ? 1 : 0,
              floorServedQuantity: 0,
              needsReview: false,
              lineKey: 'combo:food-1',
              sourceKind: 'combo_component',
            ),
            EmergencyFulfillmentItem(
              id: 'combo-food-2',
              orderItemId: 'order-item-combo',
              nameKo: '참치 김밥',
              nameVi: 'Kimbap Cá Ngừ',
              nameEn: 'Tuna Kimbap',
              orderedQuantity: 1,
              kitchenDoneQuantity: stationType == 'kitchen' ? 0 : 1,
              trayReceivedQuantity: stationType == 'floor' ? 1 : 0,
              trayDispatchedQuantity: stationType == 'floor' ? 1 : 0,
              floorServedQuantity: 0,
              needsReview: false,
              lineKey: 'combo:food-2',
              sourceKind: 'combo_component',
            ),
          ],
        ),
      ],
    );

EmergencyFulfillmentState _mixedRouteState(
  String stationType, {
  int directServedQuantity = 0,
}) => EmergencyFulfillmentState(
  assigned: true,
  active: true,
  restaurantId: 'store-bt',
  sessionId: 'session-1',
  stationType: stationType,
  floorLabel: stationType == 'floor' ? '2F' : null,
  orders: [
    EmergencyFulfillmentOrder(
      queueId: 'queue-mixed',
      orderId: 'order-mixed',
      queueNo: 202,
      tableNumber: 'T21',
      floorLabel: '2F',
      createdAt: DateTime.utc(2026, 8, 12, 10),
      items: [
        EmergencyFulfillmentItem(
          id: 'drink-1',
          orderItemId: 'order-item-drink-1',
          nameKo: '콜라',
          nameVi: 'Coca-Cola',
          nameEn: 'Cola',
          orderedQuantity: 1,
          kitchenDoneQuantity: 0,
          trayReceivedQuantity: 0,
          trayDispatchedQuantity: 0,
          floorServedQuantity: directServedQuantity,
          needsReview: false,
          fulfillmentRoute: 'floor_direct',
        ),
        EmergencyFulfillmentItem(
          id: 'food-1',
          orderItemId: 'order-item-food-1',
          nameKo: '떡볶이',
          nameVi: 'Bánh gạo cay',
          nameEn: 'Spicy rice cake',
          orderedQuantity: 1,
          kitchenDoneQuantity: stationType == 'kitchen' ? 0 : 1,
          trayReceivedQuantity: stationType == 'tray' ? 0 : 1,
          trayDispatchedQuantity: stationType == 'floor' ? 1 : 0,
          floorServedQuantity: 0,
          needsReview: false,
        ),
      ],
    ),
  ],
);

EmergencyFulfillmentState _activeState(
  String stationType, {
  int orderCount = 1,
}) => EmergencyFulfillmentState(
  assigned: true,
  active: true,
  restaurantId: 'store-bt',
  sessionId: 'session-1',
  stationType: stationType,
  floorLabel: stationType == 'floor' ? '2F' : null,
  orders: List.generate(
    orderCount,
    (index) => EmergencyFulfillmentOrder(
      queueId: 'queue-${index + 1}',
      orderId: 'order-${index + 1}',
      queueNo: 101 + index,
      tableNumber: 'T${12 + index}',
      floorLabel: '2F',
      createdAt: DateTime.utc(2026, 8, 10, 10, index),
      items: [
        EmergencyFulfillmentItem(
          id: 'item-${index + 1}',
          orderItemId: 'order-item-${index + 1}',
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
  ),
);

EmergencyFulfillmentState _completedState(String stationType) {
  final active = _activeState(stationType);
  final order = active.orders.single;
  final item = order.items.single;
  return active.copyWith(
    orders: [
      order.copyWith(
        lastActionId: 'action-1',
        lastActionAt: DateTime.utc(2026, 8, 11, 10),
        stationStartedAt: DateTime.utc(2026, 8, 11, 9, 55),
        stationCompletedAt: DateTime.utc(2026, 8, 11, 10),
        items: [item.withStage('floor_served', item.trayDispatchedQuantity)],
      ),
    ],
  );
}

EmergencyFulfillmentState _revertibleState(String stationType) {
  final active = _activeState(stationType);
  final order = active.orders.single;
  final item = order.items.single;
  final revertibleItem = switch (stationType) {
    'kitchen' => item.withStage('kitchen_done', 1),
    'tray' =>
      item.withStage('tray_received', 1).withStage('tray_dispatched', 1),
    'floor' =>
      item.withStage('tray_dispatched', 2).withStage('floor_served', 1),
    _ => item,
  };
  return active.copyWith(
    orders: [
      order.copyWith(items: [revertibleItem]),
    ],
  );
}

EmergencyFulfillmentState _activeStateWithMenuItems(
  String stationType,
  int itemCount,
) {
  final active = _activeState(stationType);
  final order = active.orders.single;
  return active.copyWith(
    orders: [
      order.copyWith(
        items: List.generate(
          itemCount,
          (index) => EmergencyFulfillmentItem(
            id: 'menu-${index + 1}',
            orderItemId: 'order-item-${index + 1}',
            nameKo: index == 1 ? '제육쌈 김밥\n[쌈야채 제공]' : '메뉴 ${index + 1}',
            nameVi: 'Món ${index + 1}',
            nameEn: 'Menu ${index + 1}',
            orderedQuantity: 1,
            kitchenDoneQuantity: 0,
            trayReceivedQuantity: 0,
            trayDispatchedQuantity: 0,
            floorServedQuantity: 0,
            needsReview: false,
          ),
        ),
      ),
    ],
  );
}

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
