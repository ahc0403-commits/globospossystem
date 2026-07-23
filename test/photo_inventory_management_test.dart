import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/inventory/inventory_provider.dart';
import 'package:globos_pos_system/features/photo_inventory/photo_inventory_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '77000000-0000-0000-0000-000000000102';

class _AuthNotifier extends AuthNotifier {
  _AuthNotifier() : super() {
    state = const PosAuthState(
      role: 'photo_objet_master',
      storeId: _storeId,
      primaryStoreId: _storeId,
      accessibleStores: [
        AccessibleStore(
          id: _storeId,
          name: 'PHOTO OBJET BIEN HOA',
          brandId: '77000000-0000-0000-0000-000000000001',
        ),
      ],
    );
  }

  @override
  Future<void> logout() async {}
}

class _IngredientNotifier extends IngredientNotifier {
  _IngredientNotifier() : super() {
    state = const IngredientState(
      items: [
        {
          'id': 'paper',
          'name': 'Photo paper',
          'current_stock': 8,
          'unit': 'ea',
        },
      ],
    );
  }

  @override
  Future<void> load(String storeId) async {}
}

Future<void> _pumpScreen(
  WidgetTester tester, {
  Size size = const Size(1200, 800),
  double textScale = 1,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetPhysicalSize);

  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _AuthNotifier()),
        ingredientProvider.overrideWith((ref) => _IngredientNotifier()),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.build(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(textScale)),
          child: child!,
        ),
        locale: const Locale('ko'),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: const PhotoInventoryScreen(autoLoad: false),
      ),
    ),
  );
  await tester.pumpAndSettle();
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

  testWidgets('PHOTO inventory shows one simple stock-status surface', (
    tester,
  ) async {
    await _pumpScreen(tester);

    expect(find.byKey(const Key('photo_inventory_root')), findsOne);
    expect(find.byKey(const Key('photo_inventory_item_list')), findsOne);
    expect(find.text('Photo paper'), findsOne);
    expect(find.textContaining('8'), findsWidgets);
    expect(find.byKey(const Key('photo_inventory_add_item')), findsOne);
  });

  testWidgets('PHOTO manager can open add and edit item forms', (tester) async {
    await _pumpScreen(tester);

    await tester.tap(find.byKey(const Key('photo_inventory_add_item')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('photo_inventory_item_dialog')), findsOne);
    expect(find.byKey(const Key('photo_inventory_item_name')), findsOne);
    expect(find.byKey(const Key('photo_inventory_current_stock')), findsOne);

    await tester.tap(find.byKey(const Key('photo_inventory_save')));
    await tester.pump();
    expect(find.text('제품명 *'), findsOne);

    await tester.tap(find.text('취소'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('photo_inventory_edit_paper')));
    await tester.pumpAndSettle();
    final nameField = tester.widget<TextField>(
      find.byKey(const Key('photo_inventory_item_name')),
    );
    final stockField = tester.widget<TextField>(
      find.byKey(const Key('photo_inventory_current_stock')),
    );
    expect(nameField.controller!.text, 'Photo paper');
    expect(stockField.controller!.text, '8');
  });

  testWidgets('PHOTO inventory remains usable on a narrow large-text screen', (
    tester,
  ) async {
    await _pumpScreen(tester, size: const Size(390, 720), textScale: 2);

    expect(find.byKey(const Key('photo_inventory_root')), findsOne);
    expect(find.byKey(const Key('photo_inventory_add_item')), findsOne);
    expect(tester.takeException(), isNull);
  });
}
