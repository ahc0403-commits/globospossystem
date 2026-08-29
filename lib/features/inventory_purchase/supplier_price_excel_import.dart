import 'dart:typed_data';

import 'package:excel/excel.dart';

const supplierPriceSheetName = '단가변경';
const supplierPriceImportMaxRows = 1000;
const supplierPriceHeaders = <String>[
  '거래처품목ID',
  '거래처',
  '원재료',
  '발주단위',
  '현재단가',
  '변경단가',
  'VAT(%)',
  '적용일',
  '메모',
];

class SupplierPriceImportWorkbook {
  const SupplierPriceImportWorkbook({required this.rows});

  final List<Map<String, dynamic>> rows;
}

class SupplierPriceImportValidationException implements Exception {
  const SupplierPriceImportValidationException(this.issues);

  final List<String> issues;

  @override
  String toString() => issues.join('\n');
}

List<int> buildSupplierPriceImportTemplate(
  List<Map<String, dynamic>> supplierItems,
) {
  final workbook = Excel.createExcel();
  workbook.rename('Sheet1', supplierPriceSheetName);
  workbook.setDefaultSheet(supplierPriceSheetName);
  final sheet = workbook[supplierPriceSheetName];
  sheet.appendRow(supplierPriceHeaders.map(TextCellValue.new).toList());

  final effectiveDate = _dateOnly(DateTime.now());
  final sorted = [...supplierItems]
    ..sort((left, right) {
      final leftSupplier = _nestedText(left['supplier'], 'supplier_name');
      final rightSupplier = _nestedText(right['supplier'], 'supplier_name');
      final supplierOrder = leftSupplier.compareTo(rightSupplier);
      if (supplierOrder != 0) return supplierOrder;
      return _nestedText(
        left['product'],
        'name',
      ).compareTo(_nestedText(right['product'], 'name'));
    });

  for (final item in sorted.where((row) => row['is_active'] != false)) {
    final currentPrice = _number(item['unit_price']);
    sheet.appendRow([
      TextCellValue(_text(item['id'])),
      TextCellValue(_nestedText(item['supplier'], 'supplier_name')),
      TextCellValue(_nestedText(item['product'], 'name')),
      TextCellValue(_text(item['order_unit'])),
      DoubleCellValue(currentPrice),
      DoubleCellValue(currentPrice),
      DoubleCellValue(_number(item['tax_rate'])),
      TextCellValue(effectiveDate),
      TextCellValue(''),
    ]);
  }

  const widths = <double>[42, 24, 28, 16, 18, 18, 14, 16, 32];
  for (var index = 0; index < widths.length; index++) {
    sheet.setColumnWidth(index, widths[index]);
  }
  return workbook.encode()!;
}

SupplierPriceImportWorkbook parseSupplierPriceImportWorkbook(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const SupplierPriceImportValidationException(['파일이 비어 있습니다.']);
  }

  late final Excel workbook;
  try {
    workbook = Excel.decodeBytes(bytes);
  } catch (_) {
    throw const SupplierPriceImportValidationException([
      'Excel 파일을 읽을 수 없습니다. .xlsx 파일인지 확인하세요.',
    ]);
  }
  final sheet = workbook.tables[supplierPriceSheetName];
  if (sheet == null || sheet.rows.isEmpty) {
    throw const SupplierPriceImportValidationException([
      '"단가변경" 시트가 없습니다. 제공된 양식을 사용하세요.',
    ]);
  }

  final headerIndexes = <String, int>{};
  for (var index = 0; index < sheet.rows.first.length; index++) {
    final header = _cellText(sheet.rows.first[index]?.value).trim();
    if (header.isNotEmpty) headerIndexes[header] = index;
  }
  final missing = supplierPriceHeaders
      .where((header) => !headerIndexes.containsKey(header))
      .toList();
  if (missing.isNotEmpty) {
    throw SupplierPriceImportValidationException([
      '필수 열이 없습니다: ${missing.join(', ')}',
    ]);
  }

  final rows = <Map<String, dynamic>>[];
  final issues = <String>[];
  final seenIds = <String>{};
  for (var index = 1; index < sheet.rows.length; index++) {
    final sourceRow = index + 1;
    final cells = sheet.rows[index];
    String cell(String header) =>
        _cellText(_cellAt(cells, headerIndexes[header]!)).trim();

    final supplierItemId = cell('거래처품목ID');
    final rawPrice = cell('변경단가').replaceAll(',', '');
    final rawTax = cell('VAT(%)').replaceAll(',', '');
    final effectiveDate = cell('적용일');
    final isBlank = supplierItemId.isEmpty && rawPrice.isEmpty;
    if (isBlank) continue;
    if (rows.length >= supplierPriceImportMaxRows) {
      issues.add(
        '$sourceRow행: 한 번에 최대 $supplierPriceImportMaxRows개까지 등록할 수 있습니다.',
      );
      break;
    }
    final price = double.tryParse(rawPrice);
    final taxRate = rawTax.isEmpty ? 0.0 : double.tryParse(rawTax);
    if (supplierItemId.isEmpty) {
      issues.add('$sourceRow행: 거래처품목ID가 없습니다.');
    } else if (!seenIds.add(supplierItemId)) {
      issues.add('$sourceRow행: 같은 거래처품목ID가 중복되었습니다.');
    }
    if (price == null || price < 0) {
      issues.add('$sourceRow행: 변경단가를 0 이상의 숫자로 입력하세요.');
    }
    if (taxRate == null || taxRate < 0 || taxRate > 100) {
      issues.add('$sourceRow행: VAT는 0~100 사이 숫자로 입력하세요.');
    }
    if (!_isDateOnly(effectiveDate)) {
      issues.add('$sourceRow행: 적용일을 YYYY-MM-DD 형식으로 입력하세요.');
    }
    if (supplierItemId.isNotEmpty && price != null && taxRate != null) {
      rows.add({
        'source_row': sourceRow,
        'supplier_item_id': supplierItemId,
        'new_unit_price': price,
        'tax_rate': taxRate,
        'effective_date': effectiveDate,
        'note': cell('메모'),
      });
    }
  }
  if (rows.isEmpty && issues.isEmpty) {
    issues.add('적용할 단가 행이 없습니다.');
  }
  if (issues.isNotEmpty) {
    throw SupplierPriceImportValidationException(issues);
  }
  return SupplierPriceImportWorkbook(rows: rows);
}

CellValue? _cellAt(List<Data?> cells, int index) =>
    index < cells.length ? cells[index]?.value : null;

String _cellText(CellValue? value) => switch (value) {
  null => '',
  TextCellValue() => value.value.toString(),
  IntCellValue() => value.value.toString(),
  DoubleCellValue() => value.value.toString(),
  BoolCellValue() => value.value ? 'true' : 'false',
  DateCellValue() =>
    '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}',
  DateTimeCellValue() =>
    '${value.year.toString().padLeft(4, '0')}-'
        '${value.month.toString().padLeft(2, '0')}-'
        '${value.day.toString().padLeft(2, '0')}',
  _ => value.toString(),
};

String _nestedText(Object? value, String key) =>
    value is Map ? _text(value[key]) : '';

String _text(Object? value) => value?.toString().trim() ?? '';

double _number(Object? value) => switch (value) {
  num number => number.toDouble(),
  _ => double.tryParse(value?.toString() ?? '') ?? 0,
};

bool _isDateOnly(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) return false;
  return DateTime.tryParse(value) != null;
}

String _dateOnly(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';
