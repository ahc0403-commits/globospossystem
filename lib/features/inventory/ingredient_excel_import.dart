import 'dart:typed_data';

import 'package:excel/excel.dart';

const ingredientImportSheetName = '원재료등록';
const ingredientSupplierReferenceSheetName = '거래처목록';
const ingredientImportMaxRows = 1000;

const ingredientImportHeaders = <String>[
  '원재료ID',
  '원재료코드',
  '원재료명',
  '분류',
  '재고표시단위',
  '기준단위',
  '표시단위환산수량',
  '보관방법',
  '유통기한(일)',
  '발주가능(Y/N)',
  '거래처',
  '가격',
];

class IngredientImportRow {
  const IngredientImportRow({
    required this.sourceRow,
    required this.productId,
    required this.productCode,
    required this.name,
    required this.category,
    required this.stockUnit,
    required this.baseUnit,
    required this.baseUnitFactor,
    required this.storageType,
    required this.shelfLifeDays,
    required this.isOrderable,
    required this.supplierId,
    required this.unitPrice,
  });

  final int sourceRow;
  final String? productId;
  final String productCode;
  final String name;
  final String? category;
  final String stockUnit;
  final String baseUnit;
  final double baseUnitFactor;
  final String? storageType;
  final int? shelfLifeDays;
  final bool isOrderable;
  final String supplierId;
  final double unitPrice;

  Map<String, dynamic> toJson() => {
    'source_row': sourceRow,
    'product_id': productId,
    'product_code': productCode,
    'name': name,
    'category': category,
    'stock_unit': stockUnit,
    'base_unit': baseUnit,
    'base_unit_factor': baseUnitFactor,
    'storage_type': storageType,
    'shelf_life_days': shelfLifeDays,
    'is_orderable': isOrderable,
    'supplier_id': supplierId,
    'unit_price': unitPrice,
  };
}

class IngredientImportWorkbook {
  const IngredientImportWorkbook({required this.rows});

  final List<IngredientImportRow> rows;

  int get rowCount => rows.length;
  int get createCount => rows.where((row) => row.productId == null).length;
  int get updateCount => rowCount - createCount;
}

class IngredientImportValidationException implements Exception {
  const IngredientImportValidationException(this.issues);

  final List<String> issues;

  @override
  String toString() => issues.join('\n');
}

List<int> buildIngredientImportTemplate({
  required List<Map<String, dynamic>> products,
  required List<Map<String, dynamic>> suppliers,
  required List<Map<String, dynamic>> supplierItems,
}) {
  final excel = Excel.createExcel();
  excel.rename('Sheet1', ingredientImportSheetName);
  excel.setDefaultSheet(ingredientImportSheetName);
  final sheet = excel[ingredientImportSheetName];
  sheet.appendRow(ingredientImportHeaders.map(TextCellValue.new).toList());

  final supplierById = <String, Map<String, dynamic>>{
    for (final supplier in suppliers)
      if (_mapText(supplier['id']).isNotEmpty &&
          (supplier['status'] == null || supplier['status'] == 'active'))
        _mapText(supplier['id']): supplier,
  };
  final supplierItemByProductId = <String, Map<String, dynamic>>{};
  for (final item in supplierItems.where(
    (item) => item['is_active'] != false,
  )) {
    final productId = _mapText(item['product_id']);
    if (productId.isEmpty) continue;
    final current = supplierItemByProductId[productId];
    if (current == null ||
        (item['is_preferred'] == true && current['is_preferred'] != true)) {
      supplierItemByProductId[productId] = item;
    }
  }

  final sorted = [...products]
    ..sort(
      (left, right) =>
          _mapText(left['name']).compareTo(_mapText(right['name'])),
    );
  if (sorted.isEmpty) {
    sheet.appendRow([
      TextCellValue(''),
      TextCellValue('ING-001'),
      TextCellValue('예: 떡'),
      TextCellValue('식재료'),
      TextCellValue('kg'),
      TextCellValue('g'),
      DoubleCellValue(1000),
      TextCellValue('냉장'),
      IntCellValue(7),
      TextCellValue('Y'),
      TextCellValue('거래처목록 시트에서 복사'),
      IntCellValue(100000),
    ]);
  } else {
    for (final product in sorted) {
      final supplierItem = supplierItemByProductId[_mapText(product['id'])];
      final supplier = supplierById[_mapText(supplierItem?['supplier_id'])];
      sheet.appendRow([
        TextCellValue(_mapText(product['id'])),
        TextCellValue(_mapText(product['product_code'])),
        TextCellValue(_mapText(product['name'])),
        TextCellValue(_mapText(product['category'])),
        TextCellValue(_mapText(product['stock_unit'])),
        TextCellValue(_mapText(product['base_unit'])),
        DoubleCellValue(_mapNumber(product['base_unit_factor']) ?? 1),
        TextCellValue(_mapText(product['storage_type'])),
        _integerCell(product['shelf_life_days']),
        TextCellValue(product['is_orderable'] == false ? 'N' : 'Y'),
        TextCellValue(_mapText(supplier?['supplier_name'])),
        _numberCell(supplierItem?['unit_price']),
      ]);
    }
  }

  const widths = <double>[38, 18, 28, 18, 18, 14, 22, 18, 18, 18, 28, 18];
  for (var index = 0; index < widths.length; index++) {
    sheet.setColumnWidth(index, widths[index]);
  }

  final supplierSheet = excel[ingredientSupplierReferenceSheetName];
  supplierSheet.appendRow([TextCellValue('거래처')]);
  final activeSuppliers =
      suppliers
          .where(
            (supplier) =>
                supplier['status'] == null || supplier['status'] == 'active',
          )
          .toList()
        ..sort(
          (left, right) => _mapText(
            left['supplier_name'],
          ).compareTo(_mapText(right['supplier_name'])),
        );
  for (final supplier in activeSuppliers) {
    final name = _mapText(supplier['supplier_name']);
    if (name.isNotEmpty) supplierSheet.appendRow([TextCellValue(name)]);
  }
  supplierSheet.setColumnWidth(0, 32);
  return excel.encode()!;
}

IngredientImportWorkbook parseIngredientImportWorkbook(
  Uint8List bytes, {
  required List<Map<String, dynamic>> existingProducts,
  required List<Map<String, dynamic>> existingSuppliers,
}) {
  if (bytes.isEmpty) {
    throw const IngredientImportValidationException(['선택한 파일이 비어 있습니다.']);
  }

  late final Excel excel;
  try {
    excel = Excel.decodeBytes(bytes);
  } catch (_) {
    throw const IngredientImportValidationException([
      'Excel 파일을 읽을 수 없습니다. .xlsx 형식인지 확인하세요.',
    ]);
  }

  final sheet = excel.tables[ingredientImportSheetName];
  if (sheet == null || sheet.rows.isEmpty) {
    throw const IngredientImportValidationException([
      '"원재료등록" 시트를 찾을 수 없습니다. 제공된 양식을 사용하세요.',
    ]);
  }

  final indexes = <String, int>{};
  for (var index = 0; index < sheet.rows.first.length; index++) {
    final header = _cellText(sheet.rows.first[index]?.value).trim();
    if (header.isNotEmpty) indexes[header] = index;
  }
  final missing = ingredientImportHeaders
      .where((header) => !indexes.containsKey(header))
      .toList();
  if (missing.isNotEmpty) {
    throw IngredientImportValidationException([
      '필수 열이 없습니다: ${missing.join(', ')}',
    ]);
  }

  final byId = <String, Map<String, dynamic>>{
    for (final product in existingProducts)
      if (_mapText(product['id']).isNotEmpty) _mapText(product['id']): product,
  };
  final byCode = <String, Map<String, dynamic>>{
    for (final product in existingProducts)
      if (_normalize(product['product_code']).isNotEmpty)
        _normalize(product['product_code']): product,
  };
  final suppliersByName = <String, List<Map<String, dynamic>>>{};
  for (final supplier in existingSuppliers.where(
    (supplier) =>
        _mapText(supplier['id']).isNotEmpty &&
        (supplier['status'] == null || supplier['status'] == 'active'),
  )) {
    final normalizedName = _normalize(supplier['supplier_name']);
    if (normalizedName.isNotEmpty) {
      suppliersByName.putIfAbsent(normalizedName, () => []).add(supplier);
    }
  }
  final issues = <String>[];
  final rows = <IngredientImportRow>[];
  final seenCodes = <String, int>{};

  for (var index = 1; index < sheet.rows.length; index++) {
    final sourceRow = index + 1;
    final cells = sheet.rows[index];
    String text(String header) =>
        _cellText(_cellAt(cells, indexes[header]!)).trim();
    final rawId = text('원재료ID');
    final code = text('원재료코드');
    final name = text('원재료명');
    final category = text('분류');
    final stockUnit = text('재고표시단위');
    final baseUnit = text('기준단위').toLowerCase();
    final rawFactor = text('표시단위환산수량');
    final storageType = text('보관방법');
    final rawShelfLife = text('유통기한(일)');
    final rawOrderable = text('발주가능(Y/N)').toUpperCase();
    final supplierName = text('거래처');
    final rawUnitPrice = text('가격');

    if ([
      rawId,
      code,
      name,
      category,
      stockUnit,
      baseUnit,
      rawFactor,
      storageType,
      rawShelfLife,
      rawOrderable,
      supplierName,
      rawUnitPrice,
    ].every((value) => value.isEmpty)) {
      continue;
    }
    if (sourceRow == 2 &&
        rawId.isEmpty &&
        code == 'ING-001' &&
        name.startsWith('예:')) {
      continue;
    }

    Map<String, dynamic>? existing;
    if (rawId.isNotEmpty) {
      existing = byId[rawId];
      if (existing == null) {
        issues.add('$sourceRow행: 현재 매장에 존재하는 원재료ID가 아닙니다.');
      }
    } else if (code.isNotEmpty) {
      existing = byCode[_normalize(code)];
    }

    if (code.isEmpty) issues.add('$sourceRow행: 원재료코드를 입력하세요.');
    if (name.isEmpty) issues.add('$sourceRow행: 원재료명을 입력하세요.');
    if (stockUnit.isEmpty) issues.add('$sourceRow행: 재고표시단위를 입력하세요.');
    if (!const {'g', 'ml', 'ea'}.contains(baseUnit)) {
      issues.add('$sourceRow행: 기준단위는 g, ml, ea 중 하나여야 합니다.');
    }
    final factor = _parseNumber(rawFactor);
    if (factor == null || factor <= 0) {
      issues.add('$sourceRow행: 표시단위환산수량은 0보다 큰 숫자여야 합니다.');
    }
    final shelfLife = rawShelfLife.isEmpty ? null : _parseInteger(rawShelfLife);
    if (rawShelfLife.isNotEmpty && (shelfLife == null || shelfLife < 0)) {
      issues.add('$sourceRow행: 유통기한은 0 이상의 정수여야 합니다.');
    }
    if (!const {'Y', 'N'}.contains(rawOrderable)) {
      issues.add('$sourceRow행: 발주가능은 Y 또는 N으로 입력하세요.');
    }
    final supplierCandidates =
        suppliersByName[_normalize(supplierName)] ??
        const <Map<String, dynamic>>[];
    final supplier = supplierCandidates.length == 1
        ? supplierCandidates.single
        : null;
    if (supplierName.isEmpty) {
      issues.add('$sourceRow행: 거래처를 입력하세요.');
    } else if (supplierCandidates.isEmpty) {
      issues.add('$sourceRow행: 현재 사용할 수 있는 거래처명을 입력하세요.');
    } else if (supplierCandidates.length > 1) {
      issues.add('$sourceRow행: 같은 이름의 거래처가 여러 개입니다. 거래처명을 고유하게 변경하세요.');
    }
    final unitPrice = _parseNumber(rawUnitPrice);
    if (unitPrice == null || !unitPrice.isFinite || unitPrice < 0) {
      issues.add('$sourceRow행: 가격은 0 이상의 숫자로 입력하세요.');
    }

    final normalizedCode = _normalize(code);
    final priorRow = seenCodes[normalizedCode];
    if (normalizedCode.isNotEmpty && priorRow != null) {
      issues.add('$sourceRow행: $priorRow행과 원재료코드가 중복됩니다.');
    } else if (normalizedCode.isNotEmpty) {
      seenCodes[normalizedCode] = sourceRow;
    }

    final existingCode = _normalize(existing?['product_code']);
    if (existing != null &&
        existingCode.isNotEmpty &&
        existingCode != normalizedCode &&
        byCode[normalizedCode] != null) {
      issues.add('$sourceRow행: 다른 원재료가 사용 중인 코드입니다.');
    }

    if (code.isNotEmpty &&
        name.isNotEmpty &&
        stockUnit.isNotEmpty &&
        const {'g', 'ml', 'ea'}.contains(baseUnit) &&
        factor != null &&
        factor > 0 &&
        (rawShelfLife.isEmpty || (shelfLife != null && shelfLife >= 0)) &&
        const {'Y', 'N'}.contains(rawOrderable) &&
        supplier != null &&
        unitPrice != null &&
        unitPrice.isFinite &&
        unitPrice >= 0) {
      rows.add(
        IngredientImportRow(
          sourceRow: sourceRow,
          productId: existing?['id']?.toString(),
          productCode: code,
          name: name,
          category: category.isEmpty ? null : category,
          stockUnit: stockUnit,
          baseUnit: baseUnit,
          baseUnitFactor: factor,
          storageType: storageType.isEmpty ? null : storageType,
          shelfLifeDays: shelfLife,
          isOrderable: rawOrderable == 'Y',
          supplierId: _mapText(supplier['id']),
          unitPrice: unitPrice,
        ),
      );
    }
  }

  if (rows.length > ingredientImportMaxRows) {
    issues.add('한 번에 최대 $ingredientImportMaxRows개 원재료만 등록할 수 있습니다.');
  }
  if (issues.isNotEmpty) {
    throw IngredientImportValidationException(issues);
  }
  if (rows.isEmpty) {
    throw const IngredientImportValidationException([
      '등록할 원재료가 없습니다. 예시 행을 실제 데이터로 교체하세요.',
    ]);
  }
  return IngredientImportWorkbook(rows: List.unmodifiable(rows));
}

CellValue? _cellAt(List<Data?> row, int index) =>
    index >= 0 && index < row.length ? row[index]?.value : null;

String _cellText(CellValue? value) => switch (value) {
  null => '',
  TextCellValue value => value.value.toString(),
  IntCellValue value => value.value.toString(),
  DoubleCellValue value => value.value.toString(),
  BoolCellValue value => value.value ? 'Y' : 'N',
  FormulaCellValue value => value.formula,
  _ => value.toString(),
};

String _mapText(Object? value) => value?.toString().trim() ?? '';
String _normalize(Object? value) => _mapText(value).toLowerCase();
double? _mapNumber(Object? value) =>
    value is num ? value.toDouble() : _parseNumber(_mapText(value));
int? _mapInt(Object? value) =>
    value is num ? value.toInt() : _parseInteger(_mapText(value));
CellValue _integerCell(Object? value) {
  final parsed = _mapInt(value);
  return parsed == null ? TextCellValue('') : IntCellValue(parsed);
}

CellValue _numberCell(Object? value) {
  final parsed = _mapNumber(value);
  if (parsed == null) return TextCellValue('');
  return parsed == parsed.truncateToDouble()
      ? IntCellValue(parsed.toInt())
      : DoubleCellValue(parsed);
}

double? _parseNumber(String value) =>
    double.tryParse(value.replaceAll(',', '').replaceAll(' ', ''));
int? _parseInteger(String value) =>
    int.tryParse(value.replaceAll(',', '').replaceAll(' ', ''));
