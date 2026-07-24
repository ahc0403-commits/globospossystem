import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_theme.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/inventory/inventory_provider.dart';
import 'package:globos_pos_system/features/inventory/recipe_excel_import.dart';
import 'package:globos_pos_system/features/inventory_purchase/inventory_purchase_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '7f6c9d22-6d84-4c7f-b923-79c81c4015d1';

const _supplier = <String, dynamic>{
  'id': 'supplier-fresh',
  'supplier_name': 'Fresh Food Saigon',
  'bank_account_number': '0123456789',
  'status': 'active',
};
const _product = <String, dynamic>{
  'id': 'product-beef',
  'product_code': 'BEEF-001',
  'name': 'Thịt bò',
  'category': 'Meat',
  'stock_unit': 'kg',
  'base_unit': 'g',
  'base_unit_factor': 1000,
  'inventory_item_id': 'ingredient-beef',
  'is_active': true,
  'is_orderable': true,
};
const _supplierItem = <String, dynamic>{
  'id': 'supplier-item-beef',
  'supplier_id': 'supplier-fresh',
  'product_id': 'product-beef',
  'supplier_sku': 'FRESH-BEEF',
  'order_unit': 'box',
  'order_unit_quantity_base': 1000,
  'min_order_quantity': 1,
  'unit_price': 250000,
  'tax_rate': 8,
  'lead_time_days': 1,
  'is_active': true,
  'product': _product,
  'supplier': _supplier,
};
const _purchaseOrder = <String, dynamic>{
  'id': 'purchase-order-1',
  'purchase_order_no': 'PO-20260718-001',
  'supplier': _supplier,
  'status': 'ordered',
  'requested_delivery_date': '2026-07-19',
  'line_count': 1,
  'total_amount': 250000,
  'total_expected_quantity_base': 1000,
  'total_received_quantity_base': 0,
  'total_remaining_quantity_base': 1000,
};
const _purchaseLine = <String, dynamic>{
  'id': 'purchase-line-1',
  'product': _product,
  'supplier_item': _supplierItem,
  'ordered_quantity': 1,
  'ordered_quantity_base': 1000,
  'received_quantity_base': 0,
  'remaining_quantity_base': 1000,
  'unit_price': 250000,
};

class _AuthNotifier extends AuthNotifier {
  _AuthNotifier() : super() {
    state = const PosAuthState(
      role: 'store_admin',
      storeId: _storeId,
      primaryStoreId: _storeId,
      accessibleStores: [
        AccessibleStore(id: _storeId, name: 'GLOBOS Nguyễn Huệ'),
      ],
    );
  }
}

class _SnapshotNotifier
    extends InventoryPurchaseRecommendationSnapshotNotifier {
  _SnapshotNotifier() {
    state = const InventoryPurchaseRecommendationSnapshotState(
      run: {'id': 'recommendation-run-1', 'run_date': '2026-07-18'},
      lines: [
        {
          'id': 'recommendation-line-1',
          'product': _product,
          'supplier': _supplier,
          'recommended_order_units': 2,
          'adjusted_order_units': null,
          'estimated_amount': 500000,
        },
      ],
    );
  }
}

class _SupplierNotifier extends InventoryPurchaseSupplierCatalogNotifier {
  _SupplierNotifier() {
    state = const InventoryPurchaseSupplierCatalogState(
      suppliers: [_supplier],
      supplierItems: [_supplierItem],
    );
  }
}

class _ProductNotifier extends InventoryPurchaseProductCatalogNotifier {
  _ProductNotifier() {
    state = const InventoryPurchaseProductCatalogState(products: [_product]);
  }
}

class _OrderSummaryNotifier extends InventoryPurchaseOrderSummaryNotifier {
  _OrderSummaryNotifier() {
    state = const InventoryPurchaseOrderSummaryState(orders: [_purchaseOrder]);
  }
}

class _OrderDetailNotifier extends InventoryPurchaseOrderDetailNotifier {
  _OrderDetailNotifier() {
    state = const InventoryPurchaseOrderDetailState(
      selectedOrderId: 'purchase-order-1',
      order: _purchaseOrder,
      lines: [_purchaseLine],
    );
  }

  @override
  Future<void> load(String orderId) async {}
}

class _StockStatusNotifier extends InventoryPurchaseStockStatusNotifier {
  _StockStatusNotifier() {
    state = const InventoryPurchaseStockStatusState(
      rows: [
        {
          'product_id': 'product-beef',
          'product_name': 'Thịt bò',
          'category': 'Meat',
          'current_stock_base': 1250,
          'base_unit': 'g',
          'risk_status': 'normal',
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

class _NewMenuNotifier extends InventoryPurchaseNewMenuNotifier {
  _NewMenuNotifier() {
    state = const InventoryPurchaseNewMenuState(
      categories: [
        {'id': 'category-main', 'name': 'Món chính'},
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

  testWidgets('all eleven Inventory Purchase dialog entrypoints execute', (
    tester,
  ) async {
    final validExcel = Excel.createExcel();
    validExcel.rename('Sheet1', recipeImportSheetName);
    final recipeSheet = validExcel[recipeImportSheetName];
    recipeSheet.appendRow(recipeImportHeaders.map(TextCellValue.new).toList());
    recipeSheet.appendRow([
      TextCellValue('menu-pho'),
      TextCellValue('Phở bò đặc biệt'),
      TextCellValue('ingredient-beef'),
      TextCellValue('Thịt bò'),
      DoubleCellValue(100),
    ]);
    final recipeFiles = <XFile>[
      XFile.fromData(
        Uint8List.fromList(validExcel.encode()!),
        name: 'recipes.xlsx',
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      ),
      XFile.fromData(
        Uint8List.fromList([1, 2, 3]),
        name: 'invalid.xlsx',
        mimeType:
            'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      ),
    ];
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(1600, 1100);
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          authProvider.overrideWith((ref) => _AuthNotifier()),
          inventoryPurchaseRecommendationSnapshotProvider.overrideWith(
            (ref) => _SnapshotNotifier(),
          ),
          inventoryPurchaseSupplierCatalogProvider.overrideWith(
            (ref) => _SupplierNotifier(),
          ),
          inventoryPurchaseProductCatalogProvider.overrideWith(
            (ref) => _ProductNotifier(),
          ),
          inventoryPurchaseOrderSummaryProvider.overrideWith(
            (ref) => _OrderSummaryNotifier(),
          ),
          inventoryPurchaseOrderDetailProvider.overrideWith(
            (ref) => _OrderDetailNotifier(),
          ),
          inventoryPurchaseStockStatusProvider.overrideWith(
            (ref) => _StockStatusNotifier(),
          ),
          recipeProvider.overrideWith((ref) => _RecipeNotifier()),
          inventoryPurchaseNewMenuProvider.overrideWith(
            (ref) => _NewMenuNotifier(),
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
          home: Scaffold(
            body: InventoryPurchaseScreen(
              initialSectionIndex: 2,
              autoLoad: false,
              pickRecipeImportFile: () async => recipeFiles.removeAt(0),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    await _openAndDismiss(
      tester,
      const Key('inventory_recommendation_run_action'),
      const Key('inventory_recommendation_run_dialog'),
    );
    await _openAndDismiss(
      tester,
      const Key('inventory_recommendation_adjust_recommendation-line-1'),
      const Key('inventory_recommendation_adjustment_dialog'),
    );
    await _openAndDismiss(
      tester,
      const Key('inventory_manual_purchase_order_action'),
      const Key('inventory_manual_purchase_order_dialog'),
    );

    await _selectSection(tester, 3);
    await _openAndDismiss(
      tester,
      const Key('inventory_repeat_purchase_order_action'),
      const Key('inventory_repeat_purchase_order_dialog'),
    );
    await _openAndDismiss(
      tester,
      const Key('inventory_receipt_confirmation_action'),
      const Key('inventory_receipt_confirmation_dialog'),
    );

    await _selectSection(tester, 4);
    await _openAndDismiss(
      tester,
      const Key('inventory_supplier_add_action'),
      const Key('inventory_supplier_dialog'),
    );
    await _openAndDismiss(
      tester,
      const Key('inventory_supplier_item_add_action'),
      const Key('inventory_supplier_item_dialog'),
    );

    await _selectSection(tester, 5);
    await _openAndDismiss(
      tester,
      const Key('inventory_product_add_action'),
      const Key('inventory_product_dialog'),
    );

    await _selectSection(tester, 6);
    expect(
      find.byKey(const Key('inventory_recipe_template_download_action')),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('inventory_recipe_excel_import_action')),
      findsOneWidget,
    );
    await _openAndDismiss(
      tester,
      const Key('inventory_recipe_excel_import_action'),
      const Key('inventory_recipe_excel_preview_dialog'),
    );
    await _openAndDismiss(
      tester,
      const Key('inventory_recipe_excel_import_action'),
      const Key('inventory_recipe_excel_error_dialog'),
    );
    await _openAndDismiss(
      tester,
      const Key('inventory_recipe_line_add_action'),
      const Key('inventory_recipe_line_dialog'),
    );

    await _selectSection(tester, 9);
    await _openAndDismiss(
      tester,
      const Key('inventory_stock_audit_action'),
      const Key('inventory_stock_audit_dialog'),
    );

    await _selectSection(tester, 10);
    await _openAndDismiss(
      tester,
      const Key('inventory_new_menu_action'),
      const Key('inventory_new_menu_dialog'),
    );

    expect(tester.takeException(), isNull);
  });
}

Future<void> _selectSection(WidgetTester tester, int index) async {
  final section = find.byKey(Key('inventory_section_$index'));
  await tester.ensureVisible(section);
  await tester.tap(section);
  await tester.pumpAndSettle();
}

Future<void> _openAndDismiss(
  WidgetTester tester,
  Key actionKey,
  Key dialogKey,
) async {
  final action = find.byKey(actionKey);
  await tester.ensureVisible(action);
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
