import 'dart:typed_data';

import 'package:excel/excel.dart';

const menuImportSheetName = '메뉴등록';
const menuImportMaxRows = 500;

const _requiredHeaders = <String>[
  '매장코드',
  '카테고리명',
  '카테고리순서',
  '메뉴명',
  '설명',
  '가격(VND)',
  '판매가능',
  'QR메뉴노출',
  '메뉴순서',
];

class MenuImportRow {
  const MenuImportRow({
    required this.sourceRow,
    required this.storeCode,
    required this.categoryName,
    required this.categorySortOrder,
    required this.name,
    required this.description,
    required this.price,
    required this.isAvailable,
    required this.isVisiblePublic,
    required this.sortOrder,
  });

  final int sourceRow;
  final String storeCode;
  final String categoryName;
  final int categorySortOrder;
  final String name;
  final String? description;
  final double price;
  final bool isAvailable;
  final bool isVisiblePublic;
  final int sortOrder;

  Map<String, dynamic> toJson() => {
    'source_row': sourceRow,
    'store_code': storeCode,
    'category_name': categoryName,
    'category_sort_order': categorySortOrder,
    'name': name,
    'description': description,
    'price': price,
    'is_available': isAvailable,
    'is_visible_public': isVisiblePublic,
    'sort_order': sortOrder,
  };
}

class MenuImportWorkbook {
  const MenuImportWorkbook({required this.rows});

  final List<MenuImportRow> rows;

  int get itemCount => rows.length;

  int get categoryCount =>
      rows.map((row) => row.categoryName.trim().toLowerCase()).toSet().length;

  Set<String> get storeCodes => rows
      .map((row) => row.storeCode.trim().toUpperCase())
      .where((code) => code.isNotEmpty)
      .toSet();
}

class MenuImportValidationException implements Exception {
  const MenuImportValidationException(this.issues);

  final List<String> issues;

  @override
  String toString() => issues.join('\n');
}

MenuImportWorkbook parseMenuImportWorkbook(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const MenuImportValidationException(['선택한 파일이 비어 있습니다.']);
  }

  late final Excel workbook;
  try {
    workbook = Excel.decodeBytes(bytes);
  } catch (_) {
    throw const MenuImportValidationException([
      'Excel 파일을 읽을 수 없습니다. .xlsx 형식인지 확인하세요.',
    ]);
  }

  final sheet = workbook.tables[menuImportSheetName];
  if (sheet == null) {
    throw const MenuImportValidationException([
      '"메뉴등록" 시트를 찾을 수 없습니다. 제공된 템플릿을 사용하세요.',
    ]);
  }
  if (sheet.rows.isEmpty) {
    throw const MenuImportValidationException(['메뉴등록 시트가 비어 있습니다.']);
  }

  final headerRow = sheet.rows.first;
  final headerIndexes = <String, int>{};
  for (var index = 0; index < headerRow.length; index++) {
    final header = _cellText(headerRow[index]?.value).trim();
    if (header.isNotEmpty) {
      headerIndexes[header] = index;
    }
  }

  final missingHeaders = _requiredHeaders
      .where((header) => !headerIndexes.containsKey(header))
      .toList();
  if (missingHeaders.isNotEmpty) {
    throw MenuImportValidationException([
      '필수 열이 없습니다: ${missingHeaders.join(', ')}',
    ]);
  }

  final issues = <String>[];
  final rows = <MenuImportRow>[];
  final duplicateKeys = <String, int>{};

  for (var index = 1; index < sheet.rows.length; index++) {
    final sourceRow = index + 1;
    final cells = sheet.rows[index];
    String text(String header) =>
        _cellText(_cellValueAt(cells, headerIndexes[header]!)).trim();

    final storeCode = text('매장코드');
    final categoryName = text('카테고리명');
    final menuName = text('메뉴명');
    final description = text('설명');
    final rawPrice = text('가격(VND)');
    final rawCategorySort = text('카테고리순서');
    final rawMenuSort = text('메뉴순서');
    final rawAvailable = text('판매가능');
    final rawPublic = text('QR메뉴노출');

    final isBlank = [
      categoryName,
      menuName,
      rawPrice,
      description,
    ].every((value) => value.isEmpty);
    if (isBlank) {
      continue;
    }

    final isTemplateExample =
        sourceRow == 2 &&
        menuName.endsWith('(예시)') &&
        description.startsWith('예시 행입니다.');
    if (isTemplateExample) {
      continue;
    }

    if (storeCode.isEmpty) {
      issues.add('$sourceRow행: 매장코드를 입력하세요.');
    }
    if (categoryName.isEmpty) {
      issues.add('$sourceRow행: 카테고리명을 입력하세요.');
    }
    if (menuName.isEmpty) {
      issues.add('$sourceRow행: 메뉴명을 입력하세요.');
    }

    final price = _parseNumber(rawPrice);
    if (price == null || price <= 0) {
      issues.add('$sourceRow행: 가격은 0보다 큰 숫자여야 합니다.');
    }

    final categorySortOrder = _parseNonNegativeInt(rawCategorySort);
    if (categorySortOrder == null) {
      issues.add('$sourceRow행: 카테고리순서는 0 이상의 정수여야 합니다.');
    }
    final menuSortOrder = _parseNonNegativeInt(rawMenuSort);
    if (menuSortOrder == null) {
      issues.add('$sourceRow행: 메뉴순서는 0 이상의 정수여야 합니다.');
    }

    final isAvailable = _parseBool(rawAvailable);
    if (isAvailable == null) {
      issues.add('$sourceRow행: 판매가능은 TRUE 또는 FALSE여야 합니다.');
    }
    final isVisiblePublic = _parseBool(rawPublic);
    if (isVisiblePublic == null) {
      issues.add('$sourceRow행: QR메뉴노출은 TRUE 또는 FALSE여야 합니다.');
    }

    if (categoryName.isNotEmpty && menuName.isNotEmpty) {
      final duplicateKey =
          '${categoryName.toLowerCase()}\u0000${menuName.toLowerCase()}';
      final priorRow = duplicateKeys[duplicateKey];
      if (priorRow != null) {
        issues.add('$sourceRow행: $priorRow행과 같은 카테고리/메뉴명이 중복됩니다.');
      } else {
        duplicateKeys[duplicateKey] = sourceRow;
      }
    }

    if (storeCode.isNotEmpty &&
        categoryName.isNotEmpty &&
        menuName.isNotEmpty &&
        price != null &&
        price > 0 &&
        categorySortOrder != null &&
        menuSortOrder != null &&
        isAvailable != null &&
        isVisiblePublic != null) {
      rows.add(
        MenuImportRow(
          sourceRow: sourceRow,
          storeCode: storeCode,
          categoryName: categoryName,
          categorySortOrder: categorySortOrder,
          name: menuName,
          description: description.isEmpty ? null : description,
          price: price,
          isAvailable: isAvailable,
          isVisiblePublic: isVisiblePublic,
          sortOrder: menuSortOrder,
        ),
      );
    }
  }

  if (rows.length > menuImportMaxRows) {
    issues.add('한 번에 최대 $menuImportMaxRows개 메뉴만 가져올 수 있습니다.');
  }
  if (issues.isNotEmpty) {
    throw MenuImportValidationException(issues);
  }
  if (rows.isEmpty) {
    throw const MenuImportValidationException([
      '등록할 메뉴가 없습니다. 예시 행을 실제 메뉴로 교체하세요.',
    ]);
  }

  final storeCodes = rows.map((row) => row.storeCode.toUpperCase()).toSet();
  if (storeCodes.length > 1) {
    throw MenuImportValidationException([
      '매장코드는 파일 전체에서 하나만 사용하세요: ${storeCodes.join(', ')}',
    ]);
  }

  return MenuImportWorkbook(rows: List.unmodifiable(rows));
}

CellValue? _cellValueAt(List<Data?> row, int index) {
  if (index < 0 || index >= row.length) {
    return null;
  }
  return row[index]?.value;
}

String _cellText(CellValue? value) {
  return switch (value) {
    null => '',
    TextCellValue value => value.value.toString(),
    IntCellValue value => value.value.toString(),
    DoubleCellValue value => value.value.toString(),
    BoolCellValue value => value.value.toString().toUpperCase(),
    FormulaCellValue value => value.formula,
    _ => value.toString(),
  };
}

double? _parseNumber(String value) {
  if (value.isEmpty) {
    return null;
  }
  return double.tryParse(value.replaceAll(',', '').replaceAll(' ', ''));
}

int? _parseNonNegativeInt(String value) {
  if (value.isEmpty) {
    return 0;
  }
  final parsedDouble = _parseNumber(value);
  if (parsedDouble == null ||
      parsedDouble < 0 ||
      parsedDouble != parsedDouble.roundToDouble()) {
    return null;
  }
  return parsedDouble.toInt();
}

bool? _parseBool(String value) {
  return switch (value.trim().toUpperCase()) {
    '' || 'TRUE' || '1' || '예' || 'Y' || 'YES' => true,
    'FALSE' || '0' || '아니오' || 'N' || 'NO' => false,
    _ => null,
  };
}
