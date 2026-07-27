import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/inventory/ingredient_excel_import.dart';

const _products = [
  {
    'id': 'product-1',
    'product_code': 'ING-001',
    'name': '떡',
    'category': '식재료',
    'stock_unit': 'kg',
    'base_unit': 'g',
    'base_unit_factor': 1000,
    'storage_type': '냉장',
    'shelf_life_days': 7,
    'is_orderable': true,
  },
];

void main() {
  test('ingredient template exports current ingredients', () {
    final excel = Excel.decodeBytes(
      buildIngredientImportTemplate(products: _products),
    );
    final sheet = excel.tables[ingredientImportSheetName]!;

    expect(sheet.maxRows, 2);
    expect(
      sheet.rows.first.map((cell) => cell?.value.toString()),
      containsAll(ingredientImportHeaders),
    );
    expect(sheet.rows[1][1]?.value.toString(), 'ING-001');
    expect(sheet.rows[1][2]?.value.toString(), '떡');
  });

  test('ingredient parser creates new rows and resolves updates by code', () {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', ingredientImportSheetName);
    final sheet = excel[ingredientImportSheetName];
    sheet.appendRow(ingredientImportHeaders.map(TextCellValue.new).toList());
    sheet.appendRow([
      TextCellValue(''),
      TextCellValue('ING-001'),
      TextCellValue('쌀떡'),
      TextCellValue('식재료'),
      TextCellValue('kg'),
      TextCellValue('g'),
      DoubleCellValue(1000),
      TextCellValue('냉장'),
      IntCellValue(5),
      TextCellValue('Y'),
    ]);
    sheet.appendRow([
      TextCellValue(''),
      TextCellValue('ING-002'),
      TextCellValue('소스'),
      TextCellValue('소스'),
      TextCellValue('L'),
      TextCellValue('ml'),
      DoubleCellValue(1000),
      TextCellValue('냉장'),
      IntCellValue(30),
      TextCellValue('N'),
    ]);

    final workbook = parseIngredientImportWorkbook(
      Uint8List.fromList(excel.encode()!),
      existingProducts: _products,
    );

    expect(workbook.rowCount, 2);
    expect(workbook.updateCount, 1);
    expect(workbook.createCount, 1);
    expect(workbook.rows.first.productId, 'product-1');
    expect(workbook.rows.last.baseUnit, 'ml');
    expect(workbook.rows.last.isOrderable, isFalse);
  });

  test('ingredient parser reports invalid units and duplicate codes', () {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', ingredientImportSheetName);
    final sheet = excel[ingredientImportSheetName];
    sheet.appendRow(ingredientImportHeaders.map(TextCellValue.new).toList());
    for (var index = 0; index < 2; index++) {
      sheet.appendRow([
        TextCellValue(''),
        TextCellValue('ING-NEW'),
        TextCellValue('원재료'),
        TextCellValue('식재료'),
        TextCellValue('kg'),
        TextCellValue('box'),
        DoubleCellValue(0),
        TextCellValue(''),
        IntCellValue(-1),
        TextCellValue('MAYBE'),
      ]);
    }

    expect(
      () => parseIngredientImportWorkbook(
        Uint8List.fromList(excel.encode()!),
        existingProducts: _products,
      ),
      throwsA(
        isA<IngredientImportValidationException>().having(
          (error) => error.issues.join('\n'),
          'issues',
          allOf(
            contains('기준단위'),
            contains('환산수량'),
            contains('유통기한'),
            contains('Y 또는 N'),
            contains('중복'),
          ),
        ),
      ),
    );
  });
}
