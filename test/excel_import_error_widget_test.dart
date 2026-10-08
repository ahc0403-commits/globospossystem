import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:globos_pos_system/features/inventory/ingredient_excel_import.dart';
import 'package:globos_pos_system/features/inventory/inventory_provider.dart';
import 'package:globos_pos_system/features/inventory_purchase/inventory_purchase_screen.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'helpers/external_excel_fixture.dart';

const _store = '7f6c9d22-6d84-4c7f-b923-79c81c4015d1';

class _Auth extends AuthNotifier {
  _Auth() {
    state = const PosAuthState(
      role: 'store_admin',
      storeId: _store,
      primaryStoreId: _store,
      accessibleStores: [AccessibleStore(id: _store, name: 'Synthetic store')],
    );
  }
}

class _Products extends InventoryPurchaseProductCatalogNotifier {
  int saveCalls = 0;

  @override
  Future<bool> bulkUpsertIngredients({
    required String storeId,
    required List<Map<String, dynamic>> rows,
  }) async {
    saveCalls++;
    return true;
  }
}

Future<_Products> _openImport(
  WidgetTester tester,
  Uint8List bytes,
  String language,
) async {
  final products = _Products();
  tester.view.physicalSize = const Size(1600, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        authProvider.overrideWith((ref) => _Auth()),
        inventoryPurchaseProductCatalogProvider.overrideWith((ref) => products),
      ],
      child: MaterialApp(
        locale: Locale(language),
        supportedLocales: AppLocalizations.supportedLocales,
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        home: Scaffold(
          body: InventoryPurchaseScreen(
            initialSectionIndex: 5,
            autoLoad: false,
            pickIngredientImportFile: () async =>
                XFile.fromData(bytes, name: 'synthetic.xlsx'),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  final action = find.byKey(
    const Key('inventory_ingredient_excel_import_action'),
  );
  await tester.ensureVisible(action);
  await tester.tap(action);
  await tester.pumpAndSettle();
  return products;
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

  for (final language in ['ko', 'en', 'vi']) {
    testWidgets(
      'unsupported format shows translated $language error before saving',
      (tester) async {
        final products = await _openImport(
          tester,
          externalExcelFixture(formatId: 55, explicitFormat: false),
          language,
        );
        final dialog = find.byKey(
          const Key('inventory_recipe_excel_error_dialog'),
        );
        expect(dialog, findsOneWidget);
        final l10n = AppLocalizations.of(tester.element(dialog))!;
        expect(
          find.text(l10n.excelImportUnsupportedNumberFormat),
          findsOneWidget,
        );
        expect(find.textContaining('numFmtId'), findsNothing);
        expect(products.saveCalls, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('price gaps still block preview and save after format repair', (
    tester,
  ) async {
    final products = await _openImport(
      tester,
      externalExcelFixture(
        sheetName: ingredientImportSheetName,
        rows: [
          ingredientImportHeaders,
          [
            '',
            'SYN-1',
            'Synthetic ingredient',
            '',
            'box',
            'g',
            1000,
            '',
            '',
            'Y',
            'Synthetic supplier',
            null,
          ],
        ],
      ),
      'ko',
    );
    expect(
      find.byKey(const Key('inventory_recipe_excel_error_dialog')),
      findsOneWidget,
    );
    expect(find.textContaining('2행: 가격'), findsOneWidget);
    expect(
      find.byKey(const Key('inventory_ingredient_excel_preview_dialog')),
      findsNothing,
    );
    expect(products.saveCalls, 0);
  });

  testWidgets(
    'repaired valid files reach preview and cancellation does not save',
    (tester) async {
      final products = await _openImport(
        tester,
        externalExcelFixture(
          sheetName: ingredientImportSheetName,
          absoluteTarget: true,
          rows: [
            ingredientImportHeaders,
            [
              '',
              'SYN-1',
              'Synthetic ingredient',
              '',
              'box',
              'g',
              1000,
              '',
              '',
              'Y',
              'Synthetic supplier',
              537037,
            ],
          ],
        ),
        'ko',
      );
      final preview = find.byKey(
        const Key('inventory_ingredient_excel_preview_dialog'),
      );
      expect(preview, findsOneWidget);
      expect(products.saveCalls, 0);
      Navigator.of(tester.element(preview)).pop(false);
      await tester.pumpAndSettle();
      expect(preview, findsNothing);
      expect(products.saveCalls, 0);
      expect(tester.takeException(), isNull);
    },
  );
}
