import '../../../core/payments/beverage_tax.dart';
import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../../../core/utils/excel_workbook_decoder.dart';

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
    this.beverageTax,
    this.nameVi,
    this.invoiceSaleUnit,
    this.menuOptions,
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

  /// Null preserves options when an older workbook omits these columns.
  final Map<String, dynamic>? menuOptions;
  final BeverageTax? beverageTax;
  final String? nameVi, invoiceSaleUnit;
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
    ...?menuOptions,
    if (beverageTax != null) ...beverageTax!.toJson(),
    'store_code': storeCode,
    'category_name': categoryName,
    'category_sort_order': categorySortOrder,
    'name': name,
    if (nameVi != null) 'name_vi': nameVi,
    if (invoiceSaleUnit != null) 'invoice_sale_unit': invoiceSaleUnit,
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
  const MenuImportValidationException(this.issues, {this.decodeFailure});

  final List<String> issues;
  final ExcelWorkbookDecodeException? decodeFailure;

  @override
  String toString() => issues.join('\n');
}

MenuImportWorkbook parseMenuImportWorkbook(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const MenuImportValidationException(['선택한 파일이 비어 있습니다.']);
  }

  late final Excel workbook;
  try {
    workbook = decodeExcelWorkbook(bytes);
  } on ExcelWorkbookDecodeException catch (error) {
    throw MenuImportValidationException([
      'Excel 파일을 읽지 못했습니다. 등록 양식에 값을 붙여넣어 다시 저장해 주세요.',
    ], decodeFailure: error);
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

    final beverageTax = parseBeverageTaxExcelRow(
      headerIndexes,
      text,
      sourceRow,
      issues,
    );
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

    final menuOptions = parseMenuOptionsExcelRow(
      headerIndexes,
      text,
      sourceRow,
      issues,
    );
    if (categoryName.isNotEmpty && menuName.isNotEmpty) {
      final duplicateKey = [
        categoryName.toLowerCase(),
        menuName.toLowerCase(),
        menuOptions?['portion_code'] ?? '',
        menuOptions?['spice_level'] ?? 'unknown',
        (menuOptions?['spice_choice'] ?? '').toString().toLowerCase(),
      ].join('\u0000');
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
          menuOptions: menuOptions,
          beverageTax: beverageTax,
          storeCode: storeCode,
          categoryName: categoryName,
          categorySortOrder: categorySortOrder,
          name: menuName,
          nameVi: headerIndexes['메뉴명(VI)'] == null
              ? null
              : _cellText(
                  _cellValueAt(cells, headerIndexes['메뉴명(VI)']!),
                ).trim(),
          invoiceSaleUnit: headerIndexes['계산서단위'] == null
              ? null
              : _cellText(_cellValueAt(cells, headerIndexes['계산서단위']!)).trim(),
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

const beverageTaxExcelHeaders = <String>['음료당류분류', '총당류(g/100ml)', '세금분류근거'];

BeverageTax? parseBeverageTaxExcelRow(
  Map<String, int> headers,
  String Function(String) text,
  int row,
  List<String> issues,
) {
  final present = beverageTaxExcelHeaders.where(headers.containsKey).length;
  if (present == 0) return null;
  if (present != beverageTaxExcelHeaders.length) {
    issues.add('$row행: 음료당류분류, 총당류(g/100ml), 세금분류근거 열을 함께 포함하세요.');
    return null;
  }
  final classification = text(beverageTaxExcelHeaders[0]);
  final rawSugar = text(beverageTaxExcelHeaders[1]);
  final basis = text(beverageTaxExcelHeaders[2]);
  // Blank optional cells preserve the current tax profile during legacy edits.
  if (classification.isEmpty && rawSugar.isEmpty && basis.isEmpty) return null;
  final tax = BeverageTax(
    sugarClass: classification,
    sugarGrams: rawSugar.isEmpty
        ? null
        : double.tryParse(rawSugar.replaceAll(',', '.')) ?? double.nan,
    basisNote: basis,
  );
  if (!tax.isValid) {
    issues.add('$row행: 음료당류분류(not_applicable/lte_5/gt_5), 당류 수치 및 근거를 확인하세요.');
    return null;
  }
  return tax;
}

const menuOptionsExcelHeaders = ['양(S/L)', '기본맵기', '맵기선택명'];
Map<String, dynamic>? parseMenuOptionsExcelRow(
  Map<String, int> headers,
  String Function(String) text,
  int row,
  List<String> issues,
) {
  final result = <String, dynamic>{};
  if (headers.containsKey('양(S/L)')) {
    final portion = text('양(S/L)').toUpperCase();
    if (!['', 'S', 'L'].contains(portion)) {
      issues.add('$row행: 양은 빈값, S 또는 L이어야 합니다.');
    }
    result['portion_code'] = portion;
  }
  if (headers.containsKey('기본맵기')) {
    final spice = text('기본맵기').isEmpty ? 'unknown' : text('기본맵기');
    if (!['unknown', 'not_spicy', 'spicy'].contains(spice)) {
      issues.add('$row행: 기본맵기는 unknown, not_spicy, spicy 중 하나여야 합니다.');
    }
    result['spice_level'] = spice;
  }
  if (headers.containsKey('맵기선택명')) {
    final choice = text('맵기선택명');
    if (choice.length > 60) issues.add('$row행: 맵기선택명은 60자 이하여야 합니다.');
    result['spice_choice'] = choice;
  }
  return result.isEmpty ? null : result;
}
