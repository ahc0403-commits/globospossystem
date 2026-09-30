import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../../core/utils/excel_workbook_decoder.dart';

const stockAuditSheet = '재고실사';
const stockAuditSettingsSheet = '설정';
const stockAuditInfoSheet = '실사정보';
const stockAuditGuideSheet = '작성안내';
const stockAuditDatedHeaders = [
  ...stockAuditHeaders,
  'supplier',
  'pos_at_reference',
];
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
  if (session['template_version'] == 2) return _buildDatedTemplate(session);
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
  final dated = session['template_version'] == 2;
  if (settings['schema'] !=
          (dated ? 'globos-stocktake-v2' : 'globos-stocktake-v1') ||
      settings['store_id'] != storeId ||
      _text(session['store_id']) != storeId) {
    throw const StockAuditImportException([
      'This stocktake file belongs to another store or format. Download a template for the selected store.',
    ]);
  }
  final replayVersion =
      dated &&
      session['status'] == 'completed' &&
      settings['version'] ==
          ((session['version'] as num).toInt() - 1).toString();
  if (settings['session_id'] != _text(session['id']) ||
      (settings['version'] != _text(session['version']) && !replayVersion) ||
      settings['exported_at'] != _text(session['exported_at'])) {
    throw const StockAuditImportException([
      'The stocktake file is outdated. Download the updated template.',
    ]);
  }
  if (dated &&
      (settings['business_date'] != _text(session['business_date']) ||
          settings['effective_at'] != _text(session['effective_at']) ||
          settings['timezone'] != 'Asia/Ho_Chi_Minh')) {
    throw const StockAuditImportException([
      '실사 기준일·시각이 변경되었습니다. 원래 양식을 사용하세요. / Count reference changed.',
    ]);
  }
  if (session['status'] != 'planned' &&
      session['status'] != 'in_progress' &&
      !(dated && session['status'] == 'completed')) {
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
  if (dated &&
      (sheet.cell(CellIndex.indexByString('B1')).value !=
              TextCellValue(_text(session['store_name'])) ||
          sheet.cell(CellIndex.indexByString('B2')).value !=
              TextCellValue(_text(session['business_date'])) ||
          sheet.cell(CellIndex.indexByString('B3')).value !=
              TextCellValue(stockAuditHcm(session['effective_at'])))) {
    throw const StockAuditImportException([
      '시트 상단의 매장·실사 날짜가 변경되었습니다. / Visible count reference has changed.',
    ]);
  }
  final headerRow = dated ? 5 : 0;
  final expectedHeaders = dated ? stockAuditDatedHeaders : stockAuditHeaders;
  if (sheet.rows.length <= headerRow) {
    throw const StockAuditImportException(['Missing stocktake headers.']);
  }
  final headers = sheet.rows[headerRow]
      .map((cell) => _cell(cell?.value))
      .toList();
  if (headers.length != expectedHeaders.length ||
      List.generate(
        headers.length,
        (i) => headers[i] == expectedHeaders[i],
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
  for (var i = headerRow + 1; i < sheet.rows.length; i++) {
    final cells = sheet.rows[i];
    if (cells.every((c) => _cell(c?.value).isEmpty)) continue;
    final values = List.generate(
      expectedHeaders.length,
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
    final unitText = _cell(values[4]).toLowerCase();
    final baseUnit = _text(target['base_unit']);
    if (!(unitText == baseUnit ||
        baseUnit == 'g' && unitText == 'kg' ||
        baseUnit == 'ml' && unitText == 'l')) {
      issues.add('Row ${i + 1}: unit has changed.');
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
    if (!_validTimestamp(timeText) ||
        time == null ||
        (!dated && time.isBefore(exportedAt)) ||
        (dated &&
            time
                    .difference(DateTime.parse(_text(session['effective_at'])))
                    .abs() >
                const Duration(days: 1)) ||
        time.isAfter(currentTime.add(const Duration(minutes: 5)))) {
      issues.add(
        'Row ${i + 1}: count time must include timezone and match the reference day.',
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
  if (seen.length != targets.length) {
    issues.add(
      '품목 행이 누락되었습니다. 빈칸이나 제외 사유를 남기고 모든 행을 유지하세요. / Missing product rows.',
    );
  }
  if (issues.isNotEmpty) throw StockAuditImportException(issues);
  return StockAuditImport(lines: lines, targetCount: targets.length);
}

Map<String, String> _settings(Excel workbook) {
  final sheet =
      workbook.tables[stockAuditInfoSheet] ??
      workbook.tables[stockAuditSettingsSheet];
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

String stockAuditHcm(dynamic timestamp) {
  final time = DateTime.tryParse(_text(timestamp));
  if (time == null) return '-';
  return '${time.toUtc().add(const Duration(hours: 7)).toIso8601String().substring(0, 19).replaceFirst('T', ' ')} +07:00';
}

String stockAuditFileName(Map<String, dynamic> session, {bool report = false}) {
  final store = _text(
    session['store_name'],
  ).replaceAll(RegExp(r'[^a-zA-Z0-9가-힣_-]+'), '_');
  final date = _text(session['business_date']).replaceAll('-', '');
  final formatted = stockAuditHcm(session['effective_at']);
  final time = formatted.length >= 16
      ? formatted.substring(11, 16).replaceAll(':', '')
      : 'unknown';
  return '${store}_${report ? '실사리포트' : '재고실사'}_${date}_${time}_${_text(session['id']).split('-').first}';
}

List<int> _buildDatedTemplate(Map<String, dynamic> session) {
  final workbook = Excel.createExcel();
  workbook.rename('Sheet1', stockAuditSheet);
  final sheet = workbook[stockAuditSheet];
  for (final row in [
    ['매장 / Store / Cửa hàng', session['store_name']],
    ['실사 업무일 / Business date / Ngày kiểm kê', session['business_date']],
    ['재고 기준시각 / Reference / Thời điểm', stockAuditHcm(session['effective_at'])],
    ['양식 생성 / Exported / Tạo mẫu', stockAuditHcm(session['exported_at'])],
    [
      _maps(session['snapshot']).any((r) => r['baseline_provisional'] == true)
          ? '사전 양식: POS 수량은 잠정값입니다. 업로드 시 기준시각 재고를 다시 계산합니다. / Provisional POS baseline.'
          : '입력: actual_quantity, counted_at, memo, excluded_reason / 수량 빈칸=미실사, 0=재고 없음',
    ],
    stockAuditDatedHeaders,
  ]) {
    sheet.appendRow(row.map((v) => TextCellValue(_text(v))).toList());
  }
  final saved = {
    for (final l in _maps(session['lines'])) _text(l['product_id']): l,
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
      TextCellValue(_text(row['supplier_name'])),
      row['current_stock_base'] == null
          ? TextCellValue('비교 불가 / N/A')
          : DoubleCellValue((row['current_stock_base'] as num).toDouble()),
    ]);
    for (final col in [3, 5, 6, 7]) {
      sheet
          .cell(
            CellIndex.indexByColumnRow(
              columnIndex: col,
              rowIndex: sheet.maxRows - 1,
            ),
          )
          .cellStyle = CellStyle(
        backgroundColorHex: ExcelColor.fromHexString('FFF2CC'),
      );
    }
  }
  final info = workbook[stockAuditInfoSheet];
  for (final row in [
    ['schema', 'globos-stocktake-v2'],
    ['store_id', session['store_id']],
    ['session_id', session['id']],
    ['version', session['version']],
    ['exported_at', session['exported_at']],
    ['counted_at', session['effective_at']],
    ['business_date', session['business_date']],
    ['effective_at', session['effective_at']],
    ['timezone', 'Asia/Ho_Chi_Minh'],
  ]) {
    info.appendRow(row.map((v) => TextCellValue(_text(v))).toList());
  }
  final guide = workbook[stockAuditGuideSheet];
  for (final text in [
    '노란 셀에 입력하세요. 제품 ID·코드·이름·날짜를 변경하거나 행을 삭제하지 마세요.',
    'Enter yellow cells. Keep every product row and the fixed store, date, IDs and codes.',
    'Nhập ô màu vàng. Không đổi ngày, mã hàng hoặc xóa dòng.',
    'actual_quantity: 기준시점의 실측 수량. 빈칸=미입력, 0=재고 없음. 여러 보관장소는 합산.',
    'g/ml/ea 기준 단위. kg→g, L→ml 변환만 지원. 포장 환산은 추정하지 마세요.',
    'counted_at: 실제 관찰시각. 기본은 실사정보의 공통 기준시각. 품목별 입력 시 +07:00 포함.',
    '관찰 중 입출고가 있었다면 정확한 관찰시각을 기록하세요. 서버에서 기준시각으로 환산합니다.',
    'excluded_reason: 제외 사유. 제외 시 수량은 비워 두세요. 완료하려면 전 품목 실사 또는 제외.',
    '다음날 업로드해도 실사 날짜는 유지됩니다. 기준 이후 입고(+), 판매·폐기(-)를 보존합니다.',
    'POS 재고는 참고값입니다. 서버가 다시 계산합니다. 사전 다운로드 값은 잠정값입니다.',
    '과거 장부 재구성/기초재고 확인은 업로드 미리보기에서 검토하세요. 임시저장은 재고 미변경.',
    '확정 파일을 수정해서 재업로드하지 마세요. 정정은 새 실사 세션으로 기록하세요.',
  ]) {
    guide.appendRow([TextCellValue(text)]);
  }
  for (var i = 0; i < stockAuditDatedHeaders.length; i++) {
    sheet.setColumnWidth(
      i,
      i == 2
          ? 52
          : i == 0
          ? 40
          : 25,
    );
  }
  info.setColumnWidth(0, 25);
  info.setColumnWidth(1, 60);
  guide.setColumnWidth(0, 125);
  return workbook.encode()!;
}

List<int> buildStockAuditReport(Map<String, dynamic> report) {
  final workbook = Excel.createExcel();
  workbook.rename('Sheet1', '실사결과');
  final sheet = workbook['실사결과'];
  sheet.appendRow([
    TextCellValue('매장'),
    TextCellValue(_text(report['store_name'])),
  ]);
  sheet.appendRow([
    TextCellValue('실사 업무일'),
    TextCellValue(_text(report['business_date'])),
  ]);
  sheet.appendRow([
    TextCellValue('기준시각'),
    TextCellValue(stockAuditHcm(report['effective_at'])),
  ]);
  sheet.appendRow([
    TextCellValue('확정시각'),
    TextCellValue(stockAuditHcm(report['completed_at'])),
  ]);
  sheet.appendRow([
    TextCellValue('조회시각'),
    TextCellValue(stockAuditHcm(report['as_of'])),
  ]);
  sheet.appendRow(
    [
      '코드',
      '품목',
      '공급처',
      '단위',
      '기준 POS',
      '실측(기준시각 환산)',
      '차이(실측-POS)',
      '단가',
      '차이금액',
      '관찰시각',
      '상태/제외',
      '이후 증감',
      '현재 계산재고',
      '관찰 수량(원본)',
    ].map(TextCellValue.new).toList(),
  );
  final movements = _maps(report['movements']);
  CellValue? number(dynamic v) =>
      v is num ? DoubleCellValue(v.toDouble()) : TextCellValue('비교 불가 / 미등록');
  for (final row in _maps(report['rows'])) {
    final net = movements
        .where((m) => m['ingredient_id'] == row['inventory_item_id'])
        .fold<double>(0, (v, m) => v + (m['quantity_base'] as num).toDouble());
    final actual = row['actual_quantity_base'];
    sheet.appendRow([
      TextCellValue(_text(row['product_code'])),
      TextCellValue(_text(row['product_name'])),
      TextCellValue(_text(row['supplier_name'])),
      TextCellValue(_text(row['base_unit'])),
      number(row['baseline_quantity_base']),
      number(actual),
      number(row['variance_quantity_base']),
      number(row['unit_cost']),
      number(row['variance_amount']),
      TextCellValue(stockAuditHcm(row['counted_at'])),
      TextCellValue(
        _text(row['excluded_reason']).isNotEmpty
            ? '제외: ${row['excluded_reason']}'
            : row['baseline_quantity_base'] == null
            ? '기초재고 / 비교 불가'
            : report['status'] == 'completed'
            ? '확정'
            : '미확정',
      ),
      DoubleCellValue(net),
      actual is num ? DoubleCellValue(actual.toDouble() + net) : null,
      number(row['observed_quantity_base'] ?? actual),
    ]);
  }
  final timeline = workbook['기준이후증감'];
  timeline.appendRow(
    [
      '날짜',
      '시각',
      '코드',
      '품목',
      '단위',
      '증감(+/-)',
      '종류',
      '원문서 종류',
      '원문서 ID',
      '비고',
    ].map(TextCellValue.new).toList(),
  );
  for (final m in movements) {
    timeline.appendRow([
      TextCellValue(_text(m['business_date'])),
      TextCellValue(stockAuditHcm(m['effective_at'])),
      TextCellValue(_text(m['product_code'])),
      TextCellValue(_text(m['product_name'])),
      TextCellValue(_text(m['base_unit'])),
      number(m['quantity_base']),
      TextCellValue(_text(m['transaction_type'])),
      TextCellValue(_text(m['reference_type'])),
      TextCellValue(_text(m['reference_id'])),
      TextCellValue(_text(m['note'])),
    ]);
  }
  for (final s in [sheet, timeline]) {
    for (var i = 0; i < 13; i++) {
      s.setColumnWidth(i, i == 1 || i == 3 ? 45 : 25);
    }
  }
  return workbook.encode()!;
}

bool _validTimestamp(String value) {
  final match = RegExp(
    r'^(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(?:\.\d{1,6})?(Z|[+-]\d{2}:\d{2})$',
  ).firstMatch(value);
  if (match == null) return false;
  final year = int.parse(match[1]!);
  final month = int.parse(match[2]!);
  final day = int.parse(match[3]!);
  final calendar = DateTime.utc(year, month, day);
  return calendar.year == year &&
      calendar.month == month &&
      calendar.day == day &&
      int.parse(match[4]!) < 24 &&
      int.parse(match[5]!) < 60 &&
      int.parse(match[6]!) < 60;
}
