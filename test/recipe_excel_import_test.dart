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
      excel.tables[recipeImportSheetName]!.rows.first
          .map((cell) => cell?.value.toString())
          .toList(),
      ['메뉴명', '재료명', '사용중량'],
    );
    expect(
      excel.tables[recipeMenuReferenceSheetName]!.maxRows,
      _menus.length + 1,
    );
    expect(
      excel.tables[recipeIngredientReferenceSheetName]!.maxRows,
      _products.length + 1,
      reason: 'all supported base-unit ingredients are recipe candidates',
    );
    expect(
      excel.tables[recipeIngredientReferenceSheetName]!.rows.first
          .map((cell) => cell?.value.toString())
          .toList(),
      ['재료명', '기준단위'],
    );
    expect(
      excel.tables[recipeIngredientReferenceSheetName]!.rows
          .map((row) => row.map((cell) => cell?.value.toString()).toList())
          .toList(),
      contains(equals(['소스', 'ml'])),
    );
  });

  test('parser accepts valid rows and preserves source row', () {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', recipeImportSheetName);
    final sheet = excel[recipeImportSheetName];
    sheet.appendRow(recipeImportHeaders.map(TextCellValue.new).toList());
    sheet.appendRow([
      TextCellValue('떡볶이'),
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
    expect(workbook.rows.single.baseUnit, 'g');
    expect(workbook.rows.single.toJson()['quantity_base'], 150);
  });

  test('parser accepts ml recipes and reports duplicate rows', () {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', recipeImportSheetName);
    final sheet = excel[recipeImportSheetName];
    sheet.appendRow(recipeImportHeaders.map(TextCellValue.new).toList());
    sheet.appendRow([
      TextCellValue('떡볶이'),
      TextCellValue('소스'),
      DoubleCellValue(10),
    ]);
    sheet.appendRow([
      TextCellValue('떡볶이'),
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
          contains('중복'),
        ),
      ),
    );
  });

  test('parser accepts a single ml recipe in its canonical base unit', () {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', recipeImportSheetName);
    final sheet = excel[recipeImportSheetName];
    sheet.appendRow(recipeImportHeaders.map(TextCellValue.new).toList());
    sheet.appendRow([
      TextCellValue('떡볶이'),
      TextCellValue('소스'),
      DoubleCellValue(25),
    ]);

    final workbook = parseRecipeImportWorkbook(
      Uint8List.fromList(excel.encode()!),
      menuItems: _menus,
      products: _products,
    );

    expect(workbook.rows.single.baseUnit, 'ml');
    expect(workbook.rows.single.quantityG, 25);
    expect(workbook.rows.single.toJson()['ingredient_unit'], 'ml');
  });

  test('parser rejects a product with an unsupported base unit', () {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', recipeImportSheetName);
    final sheet = excel[recipeImportSheetName];
    sheet.appendRow(recipeImportHeaders.map(TextCellValue.new).toList());
    sheet.appendRow([
      TextCellValue('떡볶이'),
      TextCellValue('박스 재료'),
      DoubleCellValue(1),
    ]);

    expect(
      () => parseRecipeImportWorkbook(
        Uint8List.fromList(excel.encode()!),
        menuItems: _menus,
        products: const [
          ..._products,
          {
            'id': 'product-box',
            'inventory_item_id': 'ingredient-box',
            'name': '박스 재료',
            'base_unit': 'box',
          },
        ],
      ),
      throwsA(
        isA<RecipeImportValidationException>().having(
          (error) => error.issues.join('\n'),
          'issues',
          contains('g, ml, ea'),
        ),
      ),
    );
  });

  test('parser rejects ambiguous menu and ingredient names', () {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', recipeImportSheetName);
    final sheet = excel[recipeImportSheetName];
    sheet.appendRow(recipeImportHeaders.map(TextCellValue.new).toList());
    sheet.appendRow([
      TextCellValue('떡볶이'),
      TextCellValue('떡'),
      DoubleCellValue(150),
    ]);

    expect(
      () => parseRecipeImportWorkbook(
        Uint8List.fromList(excel.encode()!),
        menuItems: const [
          ..._menus,
          {'id': 'menu-3', 'name': ' 떡볶이 '},
        ],
        products: const [
          ..._products,
          {
            'id': 'product-3',
            'inventory_item_id': 'ingredient-3',
            'name': '떡',
            'base_unit': 'g',
          },
        ],
      ),
      throwsA(
        isA<RecipeImportValidationException>().having(
          (error) => error.issues.join('\n'),
          'issues',
          allOf(contains('같은 이름의 메뉴'), contains('같은 이름의 재료')),
        ),
      ),
    );
  });
}
