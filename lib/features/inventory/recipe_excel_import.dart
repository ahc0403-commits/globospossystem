import 'dart:typed_data';

import 'package:excel/excel.dart';

const recipeImportSheetName = '레시피등록';
const recipeMenuReferenceSheetName = '메뉴목록';
const recipeIngredientReferenceSheetName = '원재료목록';
const recipeImportMaxRows = 1000;
const recipeSupportedBaseUnits = <String>{'g', 'ml', 'ea'};

const recipeImportHeaders = <String>['메뉴명', '재료명', '사용중량'];

class RecipeImportRow {
  const RecipeImportRow({
    required this.sourceRow,
    required this.menuItemId,
    required this.ingredientId,
    required this.quantityG,
    required this.baseUnit,
  });

  final int sourceRow;
  final String menuItemId;
  final String ingredientId;
  // Kept as quantityG for compatibility with the legacy menu_recipes schema.
  // The numeric value is expressed in the ingredient's canonical base unit.
  final double quantityG;
  final String baseUnit;

  Map<String, dynamic> toJson() => {
    'source_row': sourceRow,
    'menu_item_id': menuItemId,
    'ingredient_id': ingredientId,
    'quantity_g': quantityG,
    'quantity_base': quantityG,
    'ingredient_unit': baseUnit,
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
  required List<Map<String, dynamic>> recipes,
}) {
  final excel = Excel.createExcel();
  excel.rename('Sheet1', recipeImportSheetName);
  excel.setDefaultSheet(recipeImportSheetName);

  final recipeSheet = excel[recipeImportSheetName];
  recipeSheet.appendRow(recipeImportHeaders.map(TextCellValue.new).toList());
  final sortedRecipes = [...recipes]
    ..sort((left, right) {
      final menuCompare = _mapText(
        left['menu_item_name'],
      ).compareTo(_mapText(right['menu_item_name']));
      if (menuCompare != 0) return menuCompare;
      return _mapText(
        left['ingredient_name'],
      ).compareTo(_mapText(right['ingredient_name']));
    });
  for (final recipe in sortedRecipes) {
    final menuName = _mapText(recipe['menu_item_name']);
    final ingredientName = _mapText(recipe['ingredient_name']);
    final quantity = _mapNumber(recipe['quantity_g']);
    if (menuName.isEmpty || ingredientName.isEmpty || quantity == null) {
      continue;
    }
    recipeSheet.appendRow([
      TextCellValue(menuName),
      TextCellValue(ingredientName),
      DoubleCellValue(quantity),
    ]);
  }
  if (recipeSheet.maxRows == 1) {
    recipeSheet.appendRow([
      TextCellValue('메뉴목록 시트에서 복사'),
      TextCellValue('원재료목록 시트에서 복사'),
      DoubleCellValue(100),
    ]);
  }
  const recipeWidths = <double>[32, 32, 18];
  for (var index = 0; index < recipeWidths.length; index++) {
    recipeSheet.setColumnWidth(index, recipeWidths[index]);
  }

  final menuSheet = excel[recipeMenuReferenceSheetName];
  menuSheet.appendRow([TextCellValue('메뉴명')]);
  final sortedMenus = [...menuItems]
    ..sort(
      (left, right) =>
          _mapText(left['name']).compareTo(_mapText(right['name'])),
    );
  for (final menu in sortedMenus) {
    final name = _mapText(menu['name']);
    if (name.isEmpty) continue;
    menuSheet.appendRow([TextCellValue(name)]);
  }
  menuSheet.setColumnWidth(0, 32);

  final ingredientSheet = excel[recipeIngredientReferenceSheetName];
  ingredientSheet.appendRow([TextCellValue('재료명'), TextCellValue('기준단위')]);
  final sortedProducts =
      products
          .where(
            (product) =>
                _mapText(product['inventory_item_id']).isNotEmpty &&
                product['is_active'] != false &&
                recipeSupportedBaseUnits.contains(
                  _mapText(product['base_unit']).toLowerCase(),
                ),
          )
          .toList()
        ..sort(
          (left, right) =>
              _mapText(left['name']).compareTo(_mapText(right['name'])),
        );
  for (final product in sortedProducts) {
    ingredientSheet.appendRow([
      TextCellValue(_mapText(product['name'])),
      TextCellValue(_mapText(product['base_unit']).toLowerCase()),
    ]);
  }
  ingredientSheet.setColumnWidth(0, 32);
  ingredientSheet.setColumnWidth(1, 14);

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

  final menusByName = _groupByName(menuItems);
  final ingredientsByName = _groupByName(products);
  final issues = <String>[];
  final rows = <RecipeImportRow>[];
  final duplicates = <String, int>{};

  for (var index = 1; index < sheet.rows.length; index++) {
    final sourceRow = index + 1;
    final cells = sheet.rows[index];
    String text(String header) =>
        _cellText(_cellAt(cells, indexes[header]!)).trim();
    final menuName = text('메뉴명');
    final ingredientName = text('재료명');
    final rawQuantity = text('사용중량');

    if ([
      menuName,
      ingredientName,
      rawQuantity,
    ].every((value) => value.isEmpty)) {
      continue;
    }
    if (sourceRow == 2 && menuName == '메뉴목록 시트에서 복사') {
      continue;
    }

    final menuCandidates =
        menusByName[_normalize(menuName)] ?? const <Map<String, dynamic>>[];
    final ingredientCandidates =
        ingredientsByName[_normalize(ingredientName)] ??
        const <Map<String, dynamic>>[];
    final menu = menuCandidates.length == 1 ? menuCandidates.single : null;
    final ingredient = ingredientCandidates.length == 1
        ? ingredientCandidates.single
        : null;
    final quantity = _parseNumber(rawQuantity);
    if (menuName.isEmpty || menuCandidates.isEmpty) {
      issues.add('$sourceRow행: 현재 매장에 존재하는 메뉴명을 입력하세요.');
    } else if (menuCandidates.length > 1) {
      issues.add('$sourceRow행: 같은 이름의 메뉴가 여러 개입니다. 메뉴명을 고유하게 변경하세요.');
    }
    if (ingredientName.isEmpty || ingredientCandidates.isEmpty) {
      issues.add('$sourceRow행: 현재 매장에 존재하는 재료명을 입력하세요.');
    } else if (ingredientCandidates.length > 1) {
      issues.add('$sourceRow행: 같은 이름의 재료가 여러 개입니다. 재료명을 고유하게 변경하세요.');
    } else {
      final baseUnit = _mapText(ingredient!['base_unit']).toLowerCase();
      if (!recipeSupportedBaseUnits.contains(baseUnit)) {
        issues.add('$sourceRow행: 원재료의 기준단위는 g, ml, ea 중 하나여야 합니다.');
      }
    }
    if (quantity == null || quantity <= 0) {
      issues.add('$sourceRow행: 사용중량은 0보다 큰 숫자여야 합니다.');
    }

    if (menu != null && ingredient != null) {
      final menuId = _mapText(menu['id']);
      final ingredientId = _mapText(ingredient['inventory_item_id']);
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
        _mapText(menu['id']).isNotEmpty &&
        _mapText(ingredient['inventory_item_id']).isNotEmpty &&
        recipeSupportedBaseUnits.contains(
          _mapText(ingredient['base_unit']).toLowerCase(),
        ) &&
        quantity != null &&
        quantity > 0) {
      rows.add(
        RecipeImportRow(
          sourceRow: sourceRow,
          menuItemId: _mapText(menu['id']),
          ingredientId: _mapText(ingredient['inventory_item_id']),
          quantityG: quantity,
          baseUnit: _mapText(ingredient['base_unit']).toLowerCase(),
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

double? _mapNumber(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(_mapText(value).replaceAll(',', ''));
}

String _normalize(String value) =>
    value.trim().replaceAll(RegExp(r'\s+'), ' ').toLowerCase();

Map<String, List<Map<String, dynamic>>> _groupByName(
  List<Map<String, dynamic>> rows,
) {
  final grouped = <String, List<Map<String, dynamic>>>{};
  for (final row in rows) {
    final name = _normalize(_mapText(row['name']));
    if (name.isNotEmpty) grouped.putIfAbsent(name, () => []).add(row);
  }
  return grouped;
}

double? _parseNumber(String value) =>
    double.tryParse(value.replaceAll(',', '').replaceAll(' ', ''));
