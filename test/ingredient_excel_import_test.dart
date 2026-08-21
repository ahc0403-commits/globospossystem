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

const _suppliers = [
  {'id': 'supplier-1', 'supplier_name': '새벽식유통', 'status': 'active'},
];

const _supplierItems = [
  {
    'supplier_id': 'supplier-1',
    'product_id': 'product-1',
    'unit_price': 120000,
    'is_preferred': true,
    'is_active': true,
  },
];

void main() {
  test('ingredient template exports current ingredients', () {
    final excel = Excel.decodeBytes(
      buildIngredientImportTemplate(
        products: _products,
        suppliers: _suppliers,
        supplierItems: _supplierItems,
      ),
    );
    final sheet = excel.tables[ingredientImportSheetName]!;

    expect(sheet.maxRows, 2);
    expect(
      sheet.rows.first.map((cell) => cell?.value.toString()),
      containsAll(ingredientImportHeaders),
    );
    expect(sheet.rows[1][1]?.value.toString(), 'ING-001');
    expect(sheet.rows[1][2]?.value.toString(), '떡');
    expect(sheet.rows[1][10]?.value.toString(), '새벽식유통');
    expect(sheet.rows[1][11]?.value.toString(), '120000');
    expect(
      excel.tables[ingredientSupplierReferenceSheetName]!.rows[1][0]?.value
          .toString(),
      '새벽식유통',
    );
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
      TextCellValue('새벽식유통'),
      IntCellValue(120000),
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
      TextCellValue('새벽식유통'),
      IntCellValue(80000),
    ]);

    final workbook = parseIngredientImportWorkbook(
      Uint8List.fromList(excel.encode()!),
      existingProducts: _products,
      existingSuppliers: _suppliers,
    );

    expect(workbook.rowCount, 2);
    expect(workbook.updateCount, 1);
    expect(workbook.createCount, 1);
    expect(workbook.rows.first.productId, 'product-1');
    expect(workbook.rows.last.baseUnit, 'ml');
    expect(workbook.rows.last.isOrderable, isFalse);
    expect(workbook.rows.last.supplierId, 'supplier-1');
    expect(workbook.rows.last.unitPrice, 80000);
    expect(workbook.rows.last.toJson()['unit_price'], 80000);
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
        TextCellValue('없는 거래처'),
        IntCellValue(-1),
      ]);
    }

    expect(
      () => parseIngredientImportWorkbook(
        Uint8List.fromList(excel.encode()!),
        existingProducts: _products,
        existingSuppliers: _suppliers,
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
            contains('거래처명'),
            contains('가격'),
          ),
        ),
      ),
    );
  });

  test('ingredient parser rejects ambiguous supplier names', () {
    final excel = Excel.createExcel();
    excel.rename('Sheet1', ingredientImportSheetName);
    final sheet = excel[ingredientImportSheetName];
    sheet.appendRow(ingredientImportHeaders.map(TextCellValue.new).toList());
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
      TextCellValue('Y'),
      TextCellValue('새벽식유통'),
      IntCellValue(80000),
    ]);

    expect(
      () => parseIngredientImportWorkbook(
        Uint8List.fromList(excel.encode()!),
        existingProducts: _products,
        existingSuppliers: const [
          ..._suppliers,
          {'id': 'supplier-2', 'supplier_name': ' 새벽식유통 ', 'status': 'active'},
        ],
      ),
      throwsA(
        isA<IngredientImportValidationException>().having(
          (error) => error.issues.join('\n'),
          'issues',
          contains('같은 이름의 거래처'),
        ),
      ),
    );
  });
}
