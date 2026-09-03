import 'dart:convert';
import 'dart:typed_data';

import '../../core/utils/excel_workbook_decoder.dart';
import '../admin/einvoice_misa_workbook.dart';

const photoSalesImportMaxRows = 10000;

class PhotoSalesImportRow {
  const PhotoSalesImportRow({
    required this.sourceRow,
    required this.storeName,
    required this.deviceName,
    required this.deviceId,
    required this.saleTime,
    required this.amount,
    required this.type,
  });

  final int sourceRow;
  final String storeName;
  final String deviceName;
  final String deviceId;
  final String saleTime;
  final int amount;
  final String type;
}

class PhotoSalesImportWorkbook {
  const PhotoSalesImportWorkbook({
    required this.rows,
    required this.sourceSheetName,
    required this.skippedZeroAmountCount,
  });

  final List<PhotoSalesImportRow> rows;
  final String sourceSheetName;
  final int skippedZeroAmountCount;

  int get receiptCount => rows.length;
  int get totalAmount => rows.fold(0, (total, row) => total + row.amount);
  int get storeCount => rows
      .map((row) => row.storeName.trim())
      .where((name) => name.isNotEmpty)
      .toSet()
      .length;
}

class PhotoSalesImportValidationException implements Exception {
  const PhotoSalesImportValidationException(this.issues);

  final List<String> issues;

  @override
  String toString() => issues.join('\n');
}

PhotoSalesImportWorkbook parsePhotoSalesImportWorkbook(Uint8List bytes) {
  if (bytes.isEmpty) {
    throw const PhotoSalesImportValidationException(['선택한 파일이 비어 있습니다.']);
  }

  if (_looksLikeHtml(bytes)) {
    final tables = _htmlTables(utf8.decode(bytes, allowMalformed: true));
    return _parseMatrices(tables);
  }

  try {
    final workbook = decodeExcelWorkbook(bytes);
    return _parseMatrices([
      for (final entry in workbook.tables.entries)
        _SourceMatrix(
          name: entry.key,
          rows: [
            for (final row in entry.value.rows)
              [for (final cell in row) cell?.value],
          ],
        ),
    ]);
  } catch (error) {
    if (error is PhotoSalesImportValidationException) rethrow;
    throw const PhotoSalesImportValidationException([
      'Excel 파일을 읽을 수 없습니다. .xlsx 또는 Moers에서 내려받은 .xls 파일인지 확인하세요.',
    ]);
  }
}

List<int> buildPhotoSalesMisaWorkbook({
  required PhotoSalesImportWorkbook source,
  required DateTime saleDate,
}) {
  if (source.rows.isEmpty) {
    throw const PhotoSalesImportValidationException([
      'MISA 파일로 변환할 매출 행이 없습니다.',
    ]);
  }

  final date = DateTime(saleDate.year, saleDate.month, saleDate.day);
  final jobs = source.rows
      .map((row) {
        final soldAt = _soldAt(date, row.saleTime, row.sourceRow);
        return <String, dynamic>{
          'source_system': 'photo_objet_moers',
          'source_snapshot': {'sale_date': soldAt.toIso8601String()},
          'created_at': soldAt.toIso8601String(),
          'payment_method_snapshot': 'CASH',
          'buyer_snapshot': const <String, dynamic>{},
          'line_items_snapshot': [
            {
              'display_name': 'Dịch vụ chụp ảnh',
              'quantity': 1,
              'paying_amount_inc_tax': row.amount,
            },
          ],
        };
      })
      .toList(growable: false);

  return buildMisaPendingInvoiceWorkbook(jobs);
}

class _SourceMatrix {
  const _SourceMatrix({required this.name, required this.rows});

  final String name;
  final List<List<Object?>> rows;
}

PhotoSalesImportWorkbook _parseMatrices(List<_SourceMatrix> matrices) {
  for (final matrix in matrices) {
    final headerIndex = matrix.rows.indexWhere(
      (row) => row.any((cell) => _canonicalHeader(_cellText(cell)) == 'device'),
    );
    if (headerIndex < 0) continue;
    return _parseTable(matrix, headerIndex);
  }

  throw const PhotoSalesImportValidationException([
    '매출 표를 찾을 수 없습니다. 기기명(Device Name), 시간(Time), 금액(Amount) 열이 있는 Moers Excel을 사용하세요.',
  ]);
}

PhotoSalesImportWorkbook _parseTable(_SourceMatrix matrix, int headerIndex) {
  final headerCells = matrix.rows[headerIndex];
  final indexes = <String, int>{};
  for (var index = 0; index < headerCells.length; index += 1) {
    final canonical = _canonicalHeader(_cellText(headerCells[index]));
    if (canonical != null) indexes.putIfAbsent(canonical, () => index);
  }

  final missing = <String>[
    if (!indexes.containsKey('device')) '기기명(Device Name)',
    if (!indexes.containsKey('time')) '시간(Time)',
    if (!indexes.containsKey('amount')) '금액(Amount)',
  ];
  if (missing.isNotEmpty) {
    throw PhotoSalesImportValidationException([
      '필수 열이 없습니다: ${missing.join(', ')}',
    ]);
  }

  final rows = <PhotoSalesImportRow>[];
  final issues = <String>[];
  var skippedZeroAmountCount = 0;

  for (
    var rowIndex = headerIndex + 1;
    rowIndex < matrix.rows.length;
    rowIndex++
  ) {
    final cells = matrix.rows[rowIndex];
    final sourceRow = rowIndex + 1;
    Object? value(String key) {
      final index = indexes[key];
      return index == null || index >= cells.length ? null : cells[index];
    }

    final knownValues = indexes.keys.map(value).map(_cellText).toList();
    if (knownValues.every((text) => text.trim().isEmpty)) continue;

    final deviceName = _cellText(value('device')).trim();
    final saleTime = _cellText(value('time')).trim();
    final rawAmount = value('amount');
    final amount = _parseWholeAmount(rawAmount);

    if (deviceName.isEmpty) {
      issues.add('$sourceRow행: 기기명이 비어 있습니다.');
    }
    if (!_isValidSaleTime(saleTime)) {
      issues.add('$sourceRow행: 시간은 HH:mm 또는 HH:mm:ss 형식이어야 합니다.');
    }
    if (amount == null || amount < 0) {
      issues.add('$sourceRow행: 금액은 0 이상의 VND 정수여야 합니다.');
    }
    if (deviceName.isEmpty ||
        !_isValidSaleTime(saleTime) ||
        amount == null ||
        amount < 0) {
      continue;
    }
    if (amount == 0) {
      skippedZeroAmountCount += 1;
      continue;
    }

    rows.add(
      PhotoSalesImportRow(
        sourceRow: sourceRow,
        storeName: _cellText(value('store')).trim(),
        deviceName: deviceName,
        deviceId: _cellText(value('deviceId')).trim(),
        saleTime: saleTime,
        amount: amount,
        type: _cellText(value('type')).trim(),
      ),
    );
  }

  if (rows.length > photoSalesImportMaxRows) {
    issues.add('한 번에 최대 $photoSalesImportMaxRows건의 매출만 변환할 수 있습니다.');
  }
  if (rows.isEmpty && issues.isEmpty) {
    issues.add('금액이 0보다 큰 포토 매출 행이 없습니다.');
  }
  if (issues.isNotEmpty) {
    throw PhotoSalesImportValidationException(issues);
  }

  return PhotoSalesImportWorkbook(
    rows: List.unmodifiable(rows),
    sourceSheetName: matrix.name,
    skippedZeroAmountCount: skippedZeroAmountCount,
  );
}

String? _canonicalHeader(String value) {
  final normalized = value.trim().toLowerCase().replaceAll(
    RegExp(r'[\s_-]+'),
    '',
  );
  return switch (normalized) {
    '매장' || 'store' => 'store',
    '기기명' || 'devicename' => 'device',
    '기기id' || '기기아이디' || 'deviceid' => 'deviceId',
    '시간' || 'time' => 'time',
    '금액' || 'amount' => 'amount',
    '구분' || 'type' => 'type',
    _ => null,
  };
}

String _cellText(Object? value) {
  if (value == null) return '';
  return value.toString().trim();
}

int? _parseWholeAmount(Object? value) {
  if (value is int) return value;
  if (value is num) {
    if (!value.isFinite || value != value.roundToDouble()) return null;
    return value.toInt();
  }
  final normalized = _cellText(value).replaceAll(',', '').trim();
  if (!RegExp(r'^-?\d+$').hasMatch(normalized)) return null;
  return int.tryParse(normalized);
}

bool _isValidSaleTime(String value) {
  final match = RegExp(
    r'^(?:(\d{4})-(\d{2})-(\d{2})[ T])?(\d{1,2}):(\d{2})(?::(\d{2}))?$',
  ).firstMatch(value);
  if (match == null) return false;
  final hour = int.tryParse(match.group(4) ?? '');
  final minute = int.tryParse(match.group(5) ?? '');
  final second = int.tryParse(match.group(6) ?? '0');
  return hour != null &&
      minute != null &&
      second != null &&
      hour <= 23 &&
      minute <= 59 &&
      second <= 59;
}

DateTime _soldAt(DateTime saleDate, String value, int sourceRow) {
  final match = RegExp(
    r'^(?:(\d{4})-(\d{2})-(\d{2})[ T])?(\d{1,2}):(\d{2})(?::(\d{2}))?$',
  ).firstMatch(value);
  if (match == null) {
    throw PhotoSalesImportValidationException(['$sourceRow행: 시간을 읽을 수 없습니다.']);
  }

  if (match.group(1) != null) {
    final rowDate = '${match.group(1)}-${match.group(2)}-${match.group(3)}';
    final selectedDate = _dateText(saleDate);
    if (rowDate != selectedDate) {
      throw PhotoSalesImportValidationException([
        '$sourceRow행: Excel의 날짜($rowDate)가 선택한 매출일($selectedDate)과 다릅니다.',
      ]);
    }
  }

  return DateTime.utc(
    saleDate.year,
    saleDate.month,
    saleDate.day,
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    int.parse(match.group(6) ?? '0'),
  ).subtract(const Duration(hours: 7));
}

String _dateText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-'
    '${value.month.toString().padLeft(2, '0')}-'
    '${value.day.toString().padLeft(2, '0')}';

bool _looksLikeHtml(Uint8List bytes) {
  final length = bytes.length < 2048 ? bytes.length : 2048;
  final sample = utf8.decode(bytes.sublist(0, length), allowMalformed: true);
  return RegExp(r'<html|<table', caseSensitive: false).hasMatch(sample);
}

List<_SourceMatrix> _htmlTables(String html) {
  final tables = <_SourceMatrix>[];
  final tablePattern = RegExp(
    r'<table\b[^>]*>([\s\S]*?)</table>',
    caseSensitive: false,
  );
  final rowPattern = RegExp(
    r'<tr\b[^>]*>([\s\S]*?)</tr>',
    caseSensitive: false,
  );
  final cellPattern = RegExp(
    r'<t[dh]\b[^>]*>([\s\S]*?)</t[dh]>',
    caseSensitive: false,
  );

  var tableNumber = 0;
  for (final tableMatch in tablePattern.allMatches(html)) {
    tableNumber += 1;
    final rows = <List<Object?>>[];
    for (final rowMatch in rowPattern.allMatches(tableMatch.group(1)!)) {
      final cells = [
        for (final cellMatch in cellPattern.allMatches(rowMatch.group(1)!))
          _htmlText(cellMatch.group(1)!),
      ];
      if (cells.isNotEmpty && cells.any((cell) => cell.isNotEmpty)) {
        rows.add(cells);
      }
    }
    tables.add(_SourceMatrix(name: 'Table $tableNumber', rows: rows));
  }
  return tables;
}

String _htmlText(String value) {
  var text = value
      .replaceAll(RegExp(r'<[^>]+>'), '')
      .replaceAll('&nbsp;', ' ')
      .replaceAll('&amp;', '&')
      .replaceAll('&lt;', '<')
      .replaceAll('&gt;', '>')
      .replaceAll('&quot;', '"')
      .replaceAll('&#39;', "'");
  text = text.replaceAllMapped(RegExp(r'&#(\d+);'), (match) {
    final code = int.tryParse(match.group(1)!);
    return code == null ? match.group(0)! : String.fromCharCode(code);
  });
  return text.trim();
}
