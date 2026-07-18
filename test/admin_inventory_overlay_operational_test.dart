import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/admin/tabs/inventory_tab.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/inventory/inventory_provider.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '7f6c9d22-6d84-4c7f-b923-79c81c4015d1';

class _AuthNotifier extends AuthNotifier {
  _AuthNotifier() : super() {
    state = const PosAuthState(
      role: 'store_admin',
      storeId: _storeId,
      primaryStoreId: _storeId,
      accessibleStores: [
        AccessibleStore(id: _storeId, name: 'GLOBOS Nguyễn Huệ'),
      ],
      extraPermissions: ['inventory_count'],
    );
  }
}

class _IngredientNotifier extends IngredientNotifier {
  _IngredientNotifier() {
    state = const IngredientState(
      items: [
        {
          'id': 'ingredient-beef',
          'name': 'Thịt bò',
          'unit': 'g',
          'current_stock': 1250,
          'reorder_point': 500,
          'cost_per_unit': 250,
          'supplier_name': 'Fresh Food Saigon',
        },
      ],
    );
  }
}

class _RecipeNotifier extends RecipeNotifier {
  _RecipeNotifier() {
    state = const RecipeState(
      menuItems: [
        {'id': 'menu-pho', 'name': 'Phở bò đặc biệt'},
      ],
      allRecipes: [
        {
          'menu_item_id': 'menu-pho',
          'ingredient_id': 'ingredient-beef',
          'quantity_g': 100,
        },
      ],
    );
  }
}

class _OverviewNotifier extends InventoryPurchaseOverviewNotifier {
  _OverviewNotifier() {
    state = const InventoryPurchaseOverviewState(
      dashboard: {
        'store_count': 1,
        'low_stock_count': 0,
        'total_inventory_amount': 1250000,
        'submitted_purchase_amount': 0,
        'approved_purchase_amount': 0,
      },
    );
  }
}

class _SnapshotNotifier
    extends InventoryPurchaseRecommendationSnapshotNotifier {
  _SnapshotNotifier() {
    state = const InventoryPurchaseRecommendationSnapshotState(
      run: {
        'id': 'recommendation-run-20260718',
        'run_date': '2026-07-18',
        'target_stock_days': 3,
      },
      lines: [
        {'id': 'recommendation-line-beef', 'recommended_order_units': 2},
      ],
    );
  }
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

  testWidgets('all four Admin Inventory dialog entrypoints execute', (
    tester,
  ) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1440, 1000);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _AuthNotifier()),
          ingredientProvider.overrideWith((ref) => _IngredientNotifier()),
          recipeProvider.overrideWith((ref) => _RecipeNotifier()),
          inventoryPurchaseOverviewProvider.overrideWith(
            (ref) => _OverviewNotifier(),
          ),
          inventoryPurchaseRecommendationSnapshotProvider.overrideWith(
            (ref) => _SnapshotNotifier(),
          ),
        ],
        child: MaterialApp(
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
          home: const InventoryTab(autoLoad: false),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openAndDismiss(
      tester,
      const Key('admin_inventory_ingredient_add_action'),
      const Key('admin_inventory_ingredient_dialog'),
    );

    await _selectSurface(tester, 'recipe');
    await _openAndDismiss(
      tester,
      const Key('admin_inventory_recipe_add_action'),
      const Key('admin_inventory_recipe_dialog'),
    );

    await _selectSurface(tester, 'report');
    final purchaseDetail = find.byKey(
      const Key('inventory_purchase_secondary_detail'),
    );
    await tester.ensureVisible(purchaseDetail);
    await tester.tap(purchaseDetail);
    await tester.pumpAndSettle();
    await _openAndDismiss(
      tester,
      const Key('admin_inventory_recommendation_run_action'),
      const Key('admin_inventory_recommendation_run_dialog'),
    );
    await _openAndDismiss(
      tester,
      const Key('admin_inventory_create_purchase_orders_action'),
      const Key('admin_inventory_create_purchase_orders_dialog'),
    );

    expect(tester.takeException(), isNull);
  });
}

Future<void> _selectSurface(WidgetTester tester, String surface) async {
  final action = find.byKey(Key('admin_inventory_surface_$surface'));
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
}

Future<void> _openAndDismiss(
  WidgetTester tester,
  Key actionKey,
  Key dialogKey,
) async {
  final action = find.byKey(actionKey);
  await Scrollable.ensureVisible(
    tester.element(action),
    duration: Duration.zero,
  );
  await tester.pump();
  await tester.tap(action);
  await tester.pumpAndSettle();
  final dialog = find.byKey(dialogKey);
  expect(dialog, findsOneWidget, reason: '$actionKey did not open $dialogKey');
  Navigator.of(tester.element(dialog)).pop();
  await tester.pumpAndSettle();
  expect(
    tester.takeException(),
    isNull,
    reason: '$actionKey produced a rendering or lifecycle exception',
  );
}
