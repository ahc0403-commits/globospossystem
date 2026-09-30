import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../../core/utils/excel_workbook_decoder.dart';

const stockAuditSheet = '재고실사';
const stockAuditSettingsSheet = '설정';
const stockAuditHeaders = [
  'product_id',
  'item_code',
  'item_name',
  'actual_quantity',
  'unit',
  'counted_at',
  'memo',
  'excluded_reason',
];

class StockAuditImportException implements Exception {
  const StockAuditImportException(this.issues);
  final List<String> issues;
  @override
  String toString() => issues.join('\n');
}

class StockAuditImport {
  const StockAuditImport({required this.lines, required this.targetCount});
  final List<Map<String, dynamic>> lines;
  final int targetCount;
  int get countedCount =>
      lines.where((l) => l['actual_quantity_base'] != null).length;
  int get excludedCount => lines.length - countedCount;
  int get blankCount => targetCount - lines.length;
  bool get canComplete => blankCount == 0 && lines.isNotEmpty;
}

List<int> buildStockAuditTemplate(Map<String, dynamic> session) {
  final workbook = Excel.createExcel();
  workbook.rename('Sheet1', stockAuditSheet);
  final sheet = workbook[stockAuditSheet];
  sheet.appendRow(stockAuditHeaders.map(TextCellValue.new).toList());
  final saved = {
    for (final line in _maps(session['lines'])) _text(line['product_id']): line,
  };
  for (final row in _maps(session['snapshot'])) {
    final line = saved[_text(row['product_id'])];
    sheet.appendRow([
      TextCellValue(_text(row['product_id'])),
      TextCellValue(_text(row['product_code'])),
      TextCellValue(_text(row['product_name'])),
      line?['actual_quantity_base'] == null
          ? null
          : DoubleCellValue((line!['actual_quantity_base'] as num).toDouble()),
      TextCellValue(_text(row['base_unit'])),
      TextCellValue(_text(line?['counted_at'])),
      TextCellValue(_text(line?['memo'])),
      TextCellValue(_text(line?['excluded_reason'])),
    ]);
  }
  const widths = [40.0, 14.0, 52.0, 20.0, 12.0, 30.0, 32.0, 32.0];
  for (var i = 0; i < widths.length; i++) {
    sheet.setColumnWidth(i, widths[i]);
  }
  final settings = workbook[stockAuditSettingsSheet];
  for (final row in [
    ['schema', 'globos-stocktake-v1'],
    ['store_id', session['store_id']],
    ['session_id', session['id']],
    ['version', session['version'].toString()],
    ['exported_at', session['exported_at']],
    ['counted_at', ''],
    [
      'instructions',
      'Fill actual_quantity; blank = uncounted, 0 = zero stock. Keep IDs/codes unchanged.',
    ],
    [
      'units',
      'g / kg, ml / L, ea. Use base units when a package conversion is uncertain.',
    ],
    [
      'time',
      'Enter counted_at once here or per row: YYYY-MM-DDTHH:mm:ss+07:00.',
    ],
    [
      'exclude',
      'Leave quantity blank and enter excluded_reason to exclude a product explicitly.',
    ],
    [
      'stock',
      'Download after closing. Do not receive/consume stock between download and completion.',
    ],
    [
      'draft',
      'After saving a draft, download the updated template before uploading again.',
    ],
  ]) {
    settings.appendRow(row.map((v) => TextCellValue(_text(v))).toList());
  }
  settings.setColumnWidth(0, 20);
  settings.setColumnWidth(1, 105);
  return workbook.encode()!;
}

/// Read the file's session identity before fetching its authoritative snapshot.
Map<String, String> readStockAuditSettings(Uint8List bytes) {
  try {
    return _settings(decodeExcelWorkbook(bytes));
  } on StockAuditImportException {
    rethrow;
  } catch (_) {
    throw const StockAuditImportException(['Invalid XLSX workbook.']);
  }
}

StockAuditImport parseStockAuditWorkbook(
  Uint8List bytes, {
  required String storeId,
  required Map<String, dynamic> session,
  DateTime? now,
}) {
  final issues = <String>[];
  late Excel workbook;
  try {
    workbook = decodeExcelWorkbook(bytes);
  } catch (_) {
    throw const StockAuditImportException(['Invalid XLSX workbook.']);
  }
  final settings = _settings(workbook);
  if (settings['schema'] != 'globos-stocktake-v1' ||
      settings['store_id'] != storeId ||
      _text(session['store_id']) != storeId) {
    throw const StockAuditImportException([
      'This stocktake file belongs to another store or format. Download a template for the selected store.',
    ]);
  }
  if (settings['session_id'] != _text(session['id']) ||
      settings['version'] != _text(session['version']) ||
      settings['exported_at'] != _text(session['exported_at'])) {
    throw const StockAuditImportException([
      'The stocktake file is outdated. Download the updated template.',
    ]);
  }
  if (session['status'] != 'planned' && session['status'] != 'in_progress') {
    throw const StockAuditImportException([
      'This stocktake is already closed.',
    ]);
  }
  final sheet = workbook.tables[stockAuditSheet];
  if (sheet == null || sheet.maxRows < 1 || sheet.maxRows > 10001) {
    throw const StockAuditImportException([
      'Missing stocktake sheet or too many rows.',
    ]);
  }
  final headers = sheet.rows.first.map((cell) => _cell(cell?.value)).toList();
  if (headers.length != stockAuditHeaders.length ||
      List.generate(
        headers.length,
        (i) => headers[i] == stockAuditHeaders[i],
      ).contains(false)) {
    throw const StockAuditImportException([
      'Stocktake column headers have changed.',
    ]);
  }
  final targets = {
    for (final row in _maps(session['snapshot'])) _text(row['product_id']): row,
  };
  final seen = <String>{};
  final lines = <Map<String, dynamic>>[];
  final currentTime = now ?? DateTime.now();
  final exportedAt = DateTime.parse(_text(session['exported_at']));
  for (var i = 1; i < sheet.rows.length; i++) {
    final cells = sheet.rows[i];
    if (cells.every((c) => _cell(c?.value).isEmpty)) continue;
    final values = List.generate(
      8,
      (j) => j < cells.length ? cells[j]?.value : null,
    );
    if (values.any((v) => v is FormulaCellValue)) {
      issues.add('Row ${i + 1}: formulas are not allowed.');
      continue;
    }
    final id = _cell(values[0]);
    final target = targets[id];
    if (target == null || !seen.add(id)) {
      issues.add('Row ${i + 1}: unknown or duplicate product ID.');
      continue;
    }
    if (_cell(values[1]) != _text(target['product_code']) ||
        _cell(values[2]) != _text(target['product_name'])) {
      issues.add('Row ${i + 1}: product code or name has changed.');
      continue;
    }
    final rawQuantity = _cell(values[3]);
    final exclusion = _cell(values[7]);
    if (rawQuantity.isEmpty && exclusion.isEmpty) continue;
    if (exclusion.isNotEmpty) {
      if (rawQuantity.isNotEmpty) {
        issues.add(
          'Row ${i + 1}: enter a quantity or an exclusion reason, not both.',
        );
        continue;
      }
      lines.add({
        'product_id': id,
        'actual_quantity_base': null,
        'excluded_reason': exclusion,
        'counted_at': null,
        'memo': _cell(values[6]),
      });
      continue;
    }
    final quantity = double.tryParse(rawQuantity);
    final unit = _cell(values[4]).toLowerCase();
    final base = _text(target['base_unit']);
    final multiplier = unit == base
        ? 1.0
        : (base == 'g' && unit == 'kg' || base == 'ml' && unit == 'l')
        ? 1000.0
        : null;
    if (quantity == null ||
        !quantity.isFinite ||
        quantity < 0 ||
        !RegExp(r'^\d+(\.\d+)?$').hasMatch(rawQuantity) ||
        multiplier == null) {
      issues.add('Row ${i + 1}: invalid nonnegative quantity or unit.');
      continue;
    }
    final actual = quantity * multiplier;
    if (actual > 999999999.999 ||
        (actual * 1000 - (actual * 1000).round()).abs() > 0.00001) {
      issues.add(
        'Row ${i + 1}: base quantity must have at most 3 decimal places.',
      );
      continue;
    }
    final timeText = _cell(values[5]).isEmpty
        ? settings['counted_at'] ?? ''
        : _cell(values[5]);
    final time = DateTime.tryParse(timeText);
    if (!RegExp(r'(Z|[+-]\d{2}:\d{2})$').hasMatch(timeText) ||
        time == null ||
        time.isBefore(exportedAt) ||
        time.isAfter(currentTime.add(const Duration(minutes: 5)))) {
      issues.add(
        'Row ${i + 1}: enter the actual count time with timezone after template download.',
      );
      continue;
    }
    lines.add({
      'product_id': id,
      'actual_quantity_base': double.parse(actual.toStringAsFixed(3)),
      'counted_at': time.toUtc().toIso8601String(),
      'excluded_reason': null,
      'memo': _cell(values[6]),
    });
  }
  if (issues.isNotEmpty) throw StockAuditImportException(issues);
  return StockAuditImport(lines: lines, targetCount: targets.length);
}

Map<String, String> _settings(Excel workbook) {
  final sheet = workbook.tables[stockAuditSettingsSheet];
  if (sheet == null) {
    throw const StockAuditImportException([
      'Missing stocktake settings sheet.',
    ]);
  }
  final result = <String, String>{};
  for (final row in sheet.rows) {
    if (row.length < 2) continue;
    if (row.take(2).any((c) => c?.value is FormulaCellValue)) {
      throw const StockAuditImportException([
        'Settings cannot contain formulas.',
      ]);
    }
    final key = _cell(row[0]?.value);
    if (result.containsKey(key)) {
      throw const StockAuditImportException(['Duplicate stocktake settings.']);
    }
    result[key] = _cell(row[1]?.value);
  }
  return result;
}

String _cell(CellValue? value) => switch (value) {
  null => '',
  TextCellValue() => value.value.toString().trim(),
  IntCellValue() => value.value.toString(),
  DoubleCellValue() => value.value.toString(),
  _ => value.toString().trim(),
};
String _text(dynamic value) => value?.toString() ?? '';
List<Map<String, dynamic>> _maps(dynamic value) => (value as List? ?? [])
    .map((v) => Map<String, dynamic>.from(v as Map))
    .toList();
