import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/menu_service.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/admin/providers/admin_audit_provider.dart';
import 'package:globos_pos_system/features/admin/providers/menu_provider.dart';
import 'package:globos_pos_system/features/admin/tabs/menu_tab.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Auth extends AuthNotifier {
  _Auth() {
    state = const PosAuthState(role: 'store_admin', storeId: 'store');
  }
}

class _Service extends MenuService {
  int quantityWrites = 0;
  int? savedRemaining;
  int? expectedRemaining;
  @override
  Future<void> setDiscountQuantity({
    required String storeId,
    required String itemId,
    required int? remaining,
    required int? expectedRemaining,
  }) async {
    expect(storeId, 'store');
    expect(itemId, 'normal');
    quantityWrites++;
    savedRemaining = remaining;
    this.expectedRemaining = expectedRemaining;
  }

  int moves = 0;
  int reads = 0;
  String? lastMove;
  String? lastItem;
  final response = Completer<List<Map<String, dynamic>>>();
  @override
  Future<List<Map<String, dynamic>>> fetchItems(String storeId) async {
    reads++;
    return [];
  }

  @override
  Future<List<Map<String, dynamic>>> moveMenuItem({
    required String storeId,
    required String categoryId,
    required String itemId,
    required String move,
  }) {
    expect(storeId, 'store');
    expect(categoryId, 'category');
    moves++;
    lastMove = move;
    lastItem = itemId;
    return response.future;
  }
}

class _Menu extends MenuNotifier {
  _Menu(_Service service) : super('store', service: service) {
    state = MenuState(
      categories: const AsyncValue.data([
        {'id': 'category', 'name': '면류'},
        {'id': 'other', 'name': '다른 카테고리'},
      ]),
      items: AsyncValue.data([
        for (final (index, id, price) in [
          (2, 'normal', 99000),
          (4, 'second', 119000),
          (27, 'event', 55000),
        ])
          {
            'id': id,
            'name': id,
            'name_ko': id,
            'name_vi': id,
            'name_en': id,
            if (id == 'normal') 'discount_remaining': 7,
            'category_id': 'category',
            'sort_order': index,
            'price': price,
            'is_available': true,
            'is_visible_public': true,
            'menu_combo_components': <Object>[],
          },
        {'id': 'unrelated', 'category_id': 'other', 'sort_order': 90},
      ]),
      selectedCategoryId: 'category',
    );
  }
  @override
  Future<void> fetchAll() async {}
}

const _moved = [
  {'id': 'event', 'sort_order': 0},
  {'id': 'normal', 'sort_order': 1},
  {'id': 'second', 'sort_order': 2},
];

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

  testWidgets('existing menu saves remaining discount quantity independently', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final service = _Service();
    final menu = _Menu(service);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _Auth()),
          menuProvider.overrideWith((ref, store) => menu),
          adminAuditTraceProvider.overrideWith(
            (ref, store) => Future.value(const []),
          ),
        ],
        child: MaterialApp(
          theme: AppTheme.build(),
          locale: const Locale('ko'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const MenuTab(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('admin_menu_edit_item_normal')));
    await tester.pumpAndSettle();
    final field = find.byKey(const Key('admin_menu_discount_remaining'));
    expect(tester.widget<TextField>(field).controller!.text, '7');
    await tester.enterText(field, '25');
    final save = find.widgetWithText(FilledButton, '저장');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(service.quantityWrites, 1);
    expect(service.savedRemaining, 25);
    expect(service.expectedRemaining, 7);
    expect(find.byKey(const Key('admin_menu_edit_item_dialog')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  test(
    'one move applies server order without extra reads or menu data loss',
    () async {
      final service = _Service();
      final menu = _Menu(service);
      addTearDown(menu.dispose);
      final before = menu.state.items.requireValue;
      final moving = menu.moveMenuItem(
        categoryId: 'category',
        itemId: 'event',
        move: 'first',
      );
      expect(menu.state.isReorderingItems, isTrue);
      expect(
        await menu.moveMenuItem(
          categoryId: 'category',
          itemId: 'second',
          move: 'up',
        ),
        isFalse,
      );
      service.response.complete(_moved);
      expect(await moving, isTrue);
      expect(service.moves, 1);
      expect(service.reads, 0);
      expect(menu.state.selectedCategoryId, 'category');
      expect(menu.state.isReorderingItems, isFalse);
      expect(menu.state.items.requireValue.map((e) => e['id']), [
        'event',
        'normal',
        'second',
        'unrelated',
      ]);
      for (final old in before) {
        final current = menu.state.items.requireValue.singleWhere(
          (e) => e['id'] == old['id'],
        );
        expect(
          {...current}..remove('sort_order'),
          {...old}..remove('sort_order'),
        );
      }
    },
  );

  test('failed move preserves the visible rows and enables retry', () async {
    final service = _Service();
    final menu = _Menu(service);
    addTearDown(menu.dispose);
    final before = menu.state.items;
    final moving = menu.moveMenuItem(
      categoryId: 'category',
      itemId: 'event',
      move: 'up',
    );
    service.response.completeError(StateError('network unavailable'));
    expect(await moving, isFalse);
    expect(menu.state.items, same(before));
    expect(menu.state.isReorderingItems, isFalse);
  });

  for (final size in [const Size(390, 844), const Size(1440, 1000)]) {
    testWidgets('menu top/up/down controls work at $size', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = size;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final service = _Service();
      final menu = _Menu(service);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            authProvider.overrideWith((ref) => _Auth()),
            menuProvider.overrideWith((ref, store) => menu),
            adminAuditTraceProvider.overrideWith(
              (ref, store) => Future.value(const []),
            ),
          ],
          child: MaterialApp(
            theme: AppTheme.build(),
            locale: const Locale('ko'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const MenuTab(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final first = find.byKey(const Key('admin_menu_item_first_normal'));
      expect(tester.widget<IconButton>(first).onPressed, isNull);
      final last = find.byKey(const Key('admin_menu_item_first_event'));
      expect(tester.widget<IconButton>(last).onPressed, isNotNull);
      await tester.ensureVisible(last);
      await tester.pumpAndSettle();
      await tester.tap(last);
      await tester.pump();
      expect(service.lastMove, 'first');
      expect(service.lastItem, 'event');
      expect(tester.widget<IconButton>(last).onPressed, isNull);
      service.response.complete(_moved);
      await tester.pumpAndSettle();
      expect(menu.state.items.requireValue.first['id'], 'event');
      expect(tester.widget<IconButton>(last).onPressed, isNull);
      expect(service.reads, 0);
      expect(tester.takeException(), isNull);
    });
  }
}
