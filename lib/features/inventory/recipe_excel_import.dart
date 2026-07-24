import 'dart:typed_data';

import 'package:excel/excel.dart';

const recipeImportSheetName = '레시피등록';
const recipeMenuReferenceSheetName = '메뉴목록';
const recipeIngredientReferenceSheetName = '원재료목록';
const recipeImportMaxRows = 1000;

const recipeImportHeaders = <String>[
  '메뉴ID',
  '메뉴명',
  '원재료ID',
  '원재료명',
  '1인분사용량(g)',
];

class RecipeImportRow {
  const RecipeImportRow({
    required this.sourceRow,
    required this.menuItemId,
    required this.ingredientId,
    required this.quantityG,
  });

  final int sourceRow;
  final String menuItemId;
  final String ingredientId;
  final double quantityG;

  Map<String, dynamic> toJson() => {
    'source_row': sourceRow,
    'menu_item_id': menuItemId,
    'ingredient_id': ingredientId,
    'quantity_g': quantityG,
  };
}

class RecipeImportWorkbook {
  const RecipeImportWorkbook({required this.rows});

  final List<RecipeImportRow> rows;

  int get lineCount => rows.length;

  int get menuCount => rows.map((row) => row.menuItemId).toSet().length;
}

class RecipeImportValidationException implements Exception {
  const RecipeImportValidationException(this.issues);

  final List<String> issues;

  @override
  String toString() => issues.join('\n');
}

List<int> buildRecipeImportTemplate({
  required List<Map<String, dynamic>> menuItems,
  required List<Map<String, dynamic>> products,
}) {
  final excel = Excel.createExcel();
  excel.rename('Sheet1', recipeImportSheetName);
  excel.setDefaultSheet(recipeImportSheetName);

  final recipeSheet = excel[recipeImportSheetName];
  recipeSheet.appendRow(recipeImportHeaders.map(TextCellValue.new).toList());
  recipeSheet.appendRow([
    TextCellValue(''),
    TextCellValue('메뉴목록 시트에서 복사'),
    TextCellValue(''),
    TextCellValue('원재료목록 시트에서 복사'),
    DoubleCellValue(100),
  ]);
  const recipeWidths = <double>[38, 28, 38, 28, 18];
  for (var index = 0; index < recipeWidths.length; index++) {
    recipeSheet.setColumnWidth(index, recipeWidths[index]);
  }

  final menuSheet = excel[recipeMenuReferenceSheetName];
  menuSheet.appendRow([TextCellValue('메뉴ID'), TextCellValue('메뉴명')]);
  final sortedMenus = [...menuItems]
    ..sort(
      (left, right) =>
          _mapText(left['name']).compareTo(_mapText(right['name'])),
    );
  for (final menu in sortedMenus) {
    final id = _mapText(menu['id']);
    if (id.isEmpty) continue;
    menuSheet.appendRow([
      TextCellValue(id),
      TextCellValue(_mapText(menu['name'])),
    ]);
  }
  menuSheet.setColumnWidth(0, 38);
  menuSheet.setColumnWidth(1, 32);

  final ingredientSheet = excel[recipeIngredientReferenceSheetName];
  ingredientSheet.appendRow([
    TextCellValue('원재료ID'),
    TextCellValue('원재료명'),
    TextCellValue('기준단위'),
  ]);
  final sortedProducts =
      products
          .where(
            (product) =>
                _mapText(product['inventory_item_id']).isNotEmpty &&
                _mapText(product['base_unit']).toLowerCase() == 'g',
          )
          .toList()
        ..sort(
          (left, right) =>
              _mapText(left['name']).compareTo(_mapText(right['name'])),
        );
  for (final product in sortedProducts) {
    ingredientSheet.appendRow([
      TextCellValue(_mapText(product['inventory_item_id'])),
      TextCellValue(_mapText(product['name'])),
      TextCellValue('g'),
    ]);
  }
  ingredientSheet.setColumnWidth(0, 38);
  ingredientSheet.setColumnWidth(1, 32);
  ingredientSheet.setColumnWidth(2, 14);

  return excel.encode()!;
}

RecipeImportWorkbook parseRecipeImportWorkbook(
  Uint8List bytes, {
  required List<Map<String, dynamic>> menuItems,
  required List<Map<String, dynamic>> products,
}) {
  if (bytes.isEmpty) {
    throw const RecipeImportValidationException(['선택한 파일이 비어 있습니다.']);
  }

  late final Excel excel;
  try {
    excel = Excel.decodeBytes(bytes);
  } catch (_) {
    throw const RecipeImportValidationException([
      'Excel 파일을 읽을 수 없습니다. .xlsx 형식인지 확인하세요.',
    ]);
  }

  final sheet = excel.tables[recipeImportSheetName];
  if (sheet == null || sheet.rows.isEmpty) {
    throw const RecipeImportValidationException([
      '"레시피등록" 시트를 찾을 수 없습니다. 제공된 양식을 사용하세요.',
    ]);
  }

  final indexes = <String, int>{};
  for (var index = 0; index < sheet.rows.first.length; index++) {
    final header = _cellText(sheet.rows.first[index]?.value).trim();
    if (header.isNotEmpty) indexes[header] = index;
  }
  final missing = recipeImportHeaders
      .where((header) => !indexes.containsKey(header))
      .toList();
  if (missing.isNotEmpty) {
    throw RecipeImportValidationException([
      '필수 열이 없습니다: ${missing.join(', ')}',
    ]);
  }

  final menuById = <String, Map<String, dynamic>>{
    for (final menu in menuItems)
      if (_mapText(menu['id']).isNotEmpty) _mapText(menu['id']): menu,
  };
  final ingredientById = <String, Map<String, dynamic>>{
    for (final product in products)
      if (_mapText(product['inventory_item_id']).isNotEmpty)
        _mapText(product['inventory_item_id']): product,
  };
  final issues = <String>[];
  final rows = <RecipeImportRow>[];
  final duplicates = <String, int>{};

  for (var index = 1; index < sheet.rows.length; index++) {
    final sourceRow = index + 1;
    final cells = sheet.rows[index];
    String text(String header) =>
        _cellText(_cellAt(cells, indexes[header]!)).trim();
    final menuId = text('메뉴ID');
    final menuName = text('메뉴명');
    final ingredientId = text('원재료ID');
    final ingredientName = text('원재료명');
    final rawQuantity = text('1인분사용량(g)');

    if ([
      menuId,
      menuName,
      ingredientId,
      ingredientName,
      rawQuantity,
    ].every((value) => value.isEmpty)) {
      continue;
    }
    if (sourceRow == 2 &&
        menuId.isEmpty &&
        ingredientId.isEmpty &&
        menuName == '메뉴목록 시트에서 복사') {
      continue;
    }

    final menu = menuById[menuId];
    final ingredient = ingredientById[ingredientId];
    final quantity = _parseNumber(rawQuantity);
    if (menuId.isEmpty || menu == null) {
      issues.add('$sourceRow행: 현재 매장에 존재하는 메뉴ID를 입력하세요.');
    } else if (menuName.isNotEmpty &&
        _normalize(menuName) != _normalize(_mapText(menu['name']))) {
      issues.add('$sourceRow행: 메뉴ID와 메뉴명이 일치하지 않습니다.');
    }
    if (ingredientId.isEmpty || ingredient == null) {
      issues.add('$sourceRow행: 현재 매장에 존재하는 원재료ID를 입력하세요.');
    } else {
      if (_mapText(ingredient['base_unit']).toLowerCase() != 'g') {
        issues.add('$sourceRow행: g 단위 원재료만 레시피에 등록할 수 있습니다.');
      }
      if (ingredientName.isNotEmpty &&
          _normalize(ingredientName) !=
              _normalize(_mapText(ingredient['name']))) {
        issues.add('$sourceRow행: 원재료ID와 원재료명이 일치하지 않습니다.');
      }
    }
    if (quantity == null || quantity <= 0) {
      issues.add('$sourceRow행: 1인분 사용량은 0보다 큰 숫자여야 합니다.');
    }

    if (menu != null && ingredient != null) {
      final key = '$menuId\u0000$ingredientId';
      final priorRow = duplicates[key];
      if (priorRow != null) {
        issues.add('$sourceRow행: $priorRow행과 같은 메뉴/원재료가 중복됩니다.');
      } else {
        duplicates[key] = sourceRow;
      }
    }

    if (menu != null &&
        ingredient != null &&
        _mapText(ingredient['base_unit']).toLowerCase() == 'g' &&
        quantity != null &&
        quantity > 0) {
      rows.add(
        RecipeImportRow(
          sourceRow: sourceRow,
          menuItemId: menuId,
          ingredientId: ingredientId,
          quantityG: quantity,
        ),
      );
    }
  }

  if (rows.length > recipeImportMaxRows) {
    issues.add('한 번에 최대 $recipeImportMaxRows개 레시피 라인만 등록할 수 있습니다.');
  }
  if (issues.isNotEmpty) {
    throw RecipeImportValidationException(issues);
  }
  if (rows.isEmpty) {
    throw const RecipeImportValidationException([
      '등록할 레시피가 없습니다. 예시 행을 실제 데이터로 교체하세요.',
    ]);
  }
  return RecipeImportWorkbook(rows: List.unmodifiable(rows));
}

CellValue? _cellAt(List<Data?> row, int index) =>
    index >= 0 && index < row.length ? row[index]?.value : null;

String _cellText(CellValue? value) => switch (value) {
  null => '',
  TextCellValue value => value.value.toString(),
  IntCellValue value => value.value.toString(),
  DoubleCellValue value => value.value.toString(),
  BoolCellValue value => value.value.toString().toUpperCase(),
  FormulaCellValue value => value.formula,
  _ => value.toString(),
};

String _mapText(Object? value) => value?.toString().trim() ?? '';

String _normalize(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

double? _parseNumber(String value) =>
    double.tryParse(value.replaceAll(',', '').replaceAll(' ', ''));
