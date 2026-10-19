import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/inventory/ingredient_excel_import.dart';
import 'package:globos_pos_system/features/inventory/recipe_excel_import.dart';
import 'package:globos_pos_system/features/inventory_purchase/supplier_price_excel_import.dart';
import 'package:globos_pos_system/core/utils/excel_workbook_decoder.dart';

import 'helpers/external_excel_fixture.dart';

List<Object?> ingredientRow(String code, {Object? price = 537037}) => [
  '',
  code,
  'Synthetic ingredient',
  'Food',
  'box',
  'g',
  1000,
  '',
  '',
  'Y',
  'Synthetic supplier',
  price,
];

void main() {
  test(
    'external accounting files reach ingredient preview and retain values',
    () {
      final parsed = parseIngredientImportWorkbook(
        externalExcelFixture(
          sheetName: ingredientImportSheetName,
          absoluteTarget: true,
          rows: [ingredientImportHeaders, ingredientRow('00123')],
        ),
        existingProducts: [],
        existingSuppliers: [],
      );
      expect(parsed.rowCount, 1);
      expect(parsed.createCount, 1);
      expect(parsed.rows.single.productCode, '00123');
      expect(parsed.rows.single.unitPrice, 537037);
      expect(parsed.rows.single.baseUnitFactor, 1000);
    },
  );

  test('RM List-shaped files now report the missing registration sheet', () {
    expect(
      () => parseIngredientImportWorkbook(
        externalExcelFixture(
          sheetName: 'RM List',
          rows: const [
            ['번호', '거래처', '유형', '원재료', '단위', '단가', 'VAT(%)', '메모'],
            [
              1,
              'Synthetic supplier',
              'Food',
              'Ingredient',
              'box',
              537037,
              0,
              '',
            ],
          ],
        ),
        existingProducts: [],
        existingSuppliers: [],
      ),
      throwsA(
        isA<IngredientImportValidationException>()
            .having((error) => error.issues.single, 'issue', contains('원재료등록'))
            .having((error) => error.decodeFailure, 'decodeFailure', isNull),
      ),
    );
  });

  test('compatibility repair does not accept missing columns or prices', () {
    expect(
      () => parseIngredientImportWorkbook(
        externalExcelFixture(
          sheetName: ingredientImportSheetName,
          rows: const [
            ['단가'],
            [537037],
          ],
        ),
        existingProducts: [],
        existingSuppliers: [],
      ),
      throwsA(
        isA<IngredientImportValidationException>().having(
          (error) => error.issues.single,
          'issue',
          contains('필수 열'),
        ),
      ),
    );
    expect(
      () => parseIngredientImportWorkbook(
        externalExcelFixture(
          sheetName: ingredientImportSheetName,
          rows: [ingredientImportHeaders, ingredientRow('TEST', price: null)],
        ),
        existingProducts: [],
        existingSuppliers: [],
      ),
      throwsA(
        isA<IngredientImportValidationException>()
            .having((error) => error.issues.single, 'issue', contains('2행: 가격'))
            .having((error) => error.decodeFailure, 'decodeFailure', isNull),
      ),
    );
  });

  test('ingredient imports retain the 1000 row limit', () {
    final rows = [
      ingredientImportHeaders,
      for (var i = 0; i < 1000; i++) ingredientRow('SYN-$i'),
    ];
    expect(
      parseIngredientImportWorkbook(
        externalExcelFixture(sheetName: ingredientImportSheetName, rows: rows),
        existingProducts: [],
        existingSuppliers: [],
      ).rowCount,
      1000,
    );
    rows.add(ingredientRow('SYN-1000'));
    expect(
      () => parseIngredientImportWorkbook(
        externalExcelFixture(sheetName: ingredientImportSheetName, rows: rows),
        existingProducts: [],
        existingSuppliers: [],
      ),
      throwsA(
        isA<IngredientImportValidationException>().having(
          (error) => error.issues.single,
          'issue',
          contains('1000'),
        ),
      ),
    );
  });

  test(
    'recipe and supplier price imports use the same compatibility decoder',
    () {
      final recipe = parseRecipeImportWorkbook(
        externalExcelFixture(
          sheetName: recipeImportSheetName,
          rows: [
            recipeImportHeaders,
            ['Synthetic menu', 'Synthetic ingredient', 12.5],
          ],
        ),
        menuItems: [
          {'id': 'menu-1', 'name': 'Synthetic menu'},
        ],
        products: [
          {
            'id': 'product-1',
            'name': 'Synthetic ingredient',
            'inventory_item_id': 'ingredient-1',
            'base_unit': 'g',
          },
        ],
      );
      expect(recipe.rows.single.quantityG, 12.5);
      final price = parseSupplierPriceImportWorkbook(
        externalExcelFixture(
          sheetName: supplierPriceSheetName,
          absoluteTarget: true,
          rows: [
            supplierPriceHeaders,
            [
              'item-1',
              'Synthetic supplier',
              'Ingredient',
              'box',
              537037,
              537037,
              8,
              '2026-10-08',
              '',
            ],
          ],
        ),
      );
      expect(price.rows.single['new_unit_price'], 537037);
      expect(price.rows.single['effective_date'], '2026-10-08');
    },
  );

  test('supplier prices preserve real Excel date cells', () {
    final serial = DateTime.utc(
      2026,
      10,
      8,
    ).difference(DateTime.utc(1899, 12, 30)).inDays;
    final parsed = parseSupplierPriceImportWorkbook(
      externalExcelFixture(
        sheetName: supplierPriceSheetName,
        rows: [
          supplierPriceHeaders,
          [
            'item-1',
            'Synthetic supplier',
            'Ingredient',
            'box',
            537037,
            537037,
            8,
            ExternalExcelCell(serial, 2),
            '',
          ],
        ],
      ),
    );
    expect(parsed.rows.single['effective_date'], '2026-10-08');
  });

  test('unrecoverable formats retain typed diagnosis for translated UI', () {
    expect(
      () => parseIngredientImportWorkbook(
        externalExcelFixture(formatId: 55, explicitFormat: false),
        existingProducts: [],
        existingSuppliers: [],
      ),
      throwsA(
        isA<IngredientImportValidationException>().having(
          (error) => error.decodeFailure!.failure,
          'failure',
          ExcelWorkbookDecodeFailure.unsupportedNumberFormat,
        ),
      ),
    );
  });
}
