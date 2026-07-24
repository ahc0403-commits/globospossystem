import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/inventory/recipe_excel_import.dart';

const _menus = [
  {'id': 'menu-1', 'name': '떡볶이'},
  {'id': 'menu-2', 'name': '김밥'},
];

const _products = [
  {
    'id': 'product-1',
    'inventory_item_id': 'ingredient-1',
    'name': '떡',
    'base_unit': 'g',
  },
  {
    'id': 'product-2',
    'inventory_item_id': 'ingredient-2',
    'name': '소스',
    'base_unit': 'ml',
  },
];

void main() {
  test('template includes recipe and reference sheets', () {
    final bytes = buildRecipeImportTemplate(
      menuItems: _menus,
      products: _products,
    );
    final excel = Excel.decodeBytes(bytes);

    expect(excel.tables.keys, contains(recipeImportSheetName));
    expect(excel.tables.keys, contains(recipeMenuReferenceSheetName));
    expect(excel.tables.keys, contains(recipeIngredientReferenceSheetName));
    expect(
      excel.tables[recipeMenuReferenceSheetName]!.maxRows,
      _menus.length + 1,
    );
    expect(
      excel.tables[recipeIngredientReferenceSheetName]!.maxRows,
      2,
      reason: 'only gram-based ingredients are valid recipe candidates',
    );
  });

  test('parser accepts valid rows and preserves source row', () {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', recipeImportSheetName);
    final sheet = excel[recipeImportSheetName];
    sheet.appendRow(recipeImportHeaders.map(TextCellValue.new).toList());
    sheet.appendRow([
      TextCellValue('menu-1'),
      TextCellValue('떡볶이'),
      TextCellValue('ingredient-1'),
      TextCellValue('떡'),
      DoubleCellValue(150),
    ]);

    final workbook = parseRecipeImportWorkbook(
      Uint8List.fromList(excel.encode()!),
      menuItems: _menus,
      products: _products,
    );

    expect(workbook.menuCount, 1);
    expect(workbook.lineCount, 1);
    expect(workbook.rows.single.sourceRow, 2);
    expect(workbook.rows.single.quantityG, 150);
  });

  test('parser rejects unknown ids, unsupported units, and duplicates', () {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', recipeImportSheetName);
    final sheet = excel[recipeImportSheetName];
    sheet.appendRow(recipeImportHeaders.map(TextCellValue.new).toList());
    sheet.appendRow([
      TextCellValue('menu-1'),
      TextCellValue('떡볶이'),
      TextCellValue('ingredient-2'),
      TextCellValue('소스'),
      DoubleCellValue(10),
    ]);
    sheet.appendRow([
      TextCellValue('menu-1'),
      TextCellValue('떡볶이'),
      TextCellValue('ingredient-2'),
      TextCellValue('소스'),
      DoubleCellValue(20),
    ]);

    expect(
      () => parseRecipeImportWorkbook(
        Uint8List.fromList(excel.encode()!),
        menuItems: _menus,
        products: _products,
      ),
      throwsA(
        isA<RecipeImportValidationException>().having(
          (error) => error.issues.join('\n'),
          'issues',
          allOf(contains('g 단위'), contains('중복')),
        ),
      ),
    );
  });
}
