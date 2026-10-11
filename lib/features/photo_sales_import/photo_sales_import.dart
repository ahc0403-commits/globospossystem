import 'dart:convert';
import 'dart:typed_data';

import '../../core/utils/excel_workbook_decoder.dart';
import '../../core/utils/bounded_xlsx.dart';
import '../../core/utils/xlsx_rows.dart';
import '../admin/einvoice_misa_workbook.dart';

const photoSalesImportMaxRows = 10000;

const photoSalesBranchLabels = <String, String>{
  'BH': 'PHOTO OBJET BIEN HOA',
  'DA': 'PHOTO OBJET DI AN',
  'LT': 'PHOTO OBJET LONG THANH',
  'TD': 'PHOTO OBJET THAO DIEN',
  'QT': 'PHOTO OBJET QUANG TRUNG',
  'NZ': 'PHOTO OBJET NOW ZONE',
};

class PhotoSalesImportRow {
  const PhotoSalesImportRow({
    required this.sourceRow,
    required this.branchCode,
    required this.storeName,
    required this.deviceName,
    required this.deviceId,
    required this.saleTime,
    required this.amount,
    required this.type,
  });

  final int sourceRow;
  final String branchCode;
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

  Map<String, dynamic> toJson() => {
    'source_sheet_name': sourceSheetName,
    'skipped_zero': skippedZeroAmountCount,
    'rows': rows
        .map(
          (r) => {
            'source_row': r.sourceRow,
            'branch_code': r.branchCode,
            'store_name': r.storeName,
            'device_name': r.deviceName,
            'device_id': r.deviceId,
            'sale_time': r.saleTime,
            'amount': r.amount,
            'type': r.type,
          },
        )
        .toList(growable: false),
  };
  factory PhotoSalesImportWorkbook.fromJson(Map<String, dynamic> json) =>
      PhotoSalesImportWorkbook(
        sourceSheetName: json['source_sheet_name'] as String,
        skippedZeroAmountCount: json['skipped_zero'] as int,
        rows: (json['rows'] as List)
            .map((raw) {
              final r = raw as Map;
              return PhotoSalesImportRow(
                sourceRow: r['source_row'] as int,
                branchCode: r['branch_code'] as String,
                storeName: r['store_name'] as String,
                deviceName: r['device_name'] as String,
                deviceId: r['device_id'] as String,
                saleTime: r['sale_time'] as String,
                amount: r['amount'] as int,
                type: r['type'] as String,
              );
            })
            .toList(growable: false),
      );

  int get receiptCount => rows.length;
  int get totalAmount => rows.fold(0, (total, row) => total + row.amount);
  int get storeCount => branchSummaries.length;

  List<PhotoSalesBranchSummary> get branchSummaries {
    final grouped = <String, List<PhotoSalesImportRow>>{};
    for (final row in rows) {
      grouped.putIfAbsent(row.branchCode, () => []).add(row);
    }
    return [
      for (final entry in grouped.entries)
        PhotoSalesBranchSummary(
          branchCode: entry.key,
          storeName:
              photoSalesBranchLabels[entry.key] ??
              entry.value.first.storeName.trim(),
          receiptCount: entry.value.length,
          totalAmount: entry.value.fold(0, (total, row) => total + row.amount),
        ),
    ]..sort((a, b) => a.storeName.compareTo(b.storeName));
  }
}

class PhotoSalesBranchSummary {
  const PhotoSalesBranchSummary({
    required this.branchCode,
    required this.storeName,
    required this.receiptCount,
    required this.totalAmount,
  });

  final String branchCode;
  final String storeName;
  final int receiptCount;
  final int totalAmount;
}

class PhotoSalesImportValidationException implements Exception {
  const PhotoSalesImportValidationException(this.issues, {this.decodeFailure});

  final List<String> issues;
  final ExcelWorkbookDecodeException? decodeFailure;

  @override
  String toString() => issues.join('\n');
}

PhotoSalesImportWorkbook parsePhotoSalesImportWorkbook(Uint8List bytes) {
  if (bytes.length > excelMaxCompressedBytes) {
    throw const PhotoSalesImportValidationException([
      'Excel 파일은 최대 10 MiB까지 읽을 수 있습니다.',
    ]);
  }
  if (bytes.isEmpty) {
    throw const PhotoSalesImportValidationException(['선택한 파일이 비어 있습니다.']);
  }

  if (_looksLikeHtml(bytes)) {
    final tables = _htmlTables(utf8.decode(bytes, allowMalformed: true));
    return _parseMatrices(tables);
  }

  try {
    return _parseMatrices(
      readXlsxRows(
        bytes,
      ).map((sheet) => _SourceMatrix(name: sheet.name, rows: sheet.rows)),
    );
  } catch (error) {
    if (error is PhotoSalesImportValidationException) rethrow;
    throw PhotoSalesImportValidationException([
      'Excel 파일을 읽지 못했습니다. 파일을 확인한 뒤 다시 저장해 주세요.',
    ], decodeFailure: error is ExcelWorkbookDecodeException ? error : null);
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

List<Map<String, dynamic>> buildPhotoSalesRegistrationRows({
  required PhotoSalesImportWorkbook source,
  required DateTime saleDate,
}) {
  if (source.rows.isEmpty) {
    throw const PhotoSalesImportValidationException(['지점 매출로 등록할 행이 없습니다.']);
  }

  final date = DateTime(saleDate.year, saleDate.month, saleDate.day);
  final occurrences = <String, int>{};
  return source.rows
      .map((row) {
        final soldAt = _soldAt(date, row.saleTime, row.sourceRow);
        final saleTime = _canonicalSaleTime(row.saleTime);
        final identity = jsonEncode([
          row.branchCode,
          row.deviceId,
          row.deviceName,
          soldAt.toIso8601String(),
          row.amount,
          row.type,
        ]);
        final occurrenceNo = (occurrences[identity] ?? 0) + 1;
        occurrences[identity] = occurrenceNo;
        return <String, dynamic>{
          'source_row': row.sourceRow,
          'branch_code': row.branchCode,
          'store_name': row.storeName,
          'device_name': row.deviceName,
          'device_id': row.deviceId,
          'sale_time': saleTime,
          'amount': row.amount,
          'raw_type': row.type,
          'occurrence_no': occurrenceNo,
        };
      })
      .toList(growable: false);
}

class _SourceMatrix {
  const _SourceMatrix({required this.name, required this.rows});

  final String name;
  final Iterable<List<Object?>> rows;
}

PhotoSalesImportWorkbook _parseMatrices(Iterable<_SourceMatrix> matrices) {
  for (final matrix in matrices) {
    final iterator = matrix.rows.iterator;
    var index = -1;
    while (iterator.moveNext()) {
      index++;
      if (iterator.current.any(
        (cell) => _canonicalHeader(_cellText(cell)) == 'device',
      )) {
        return _parseTable(matrix.name, iterator.current, iterator, index);
      }
    }
  }

  throw const PhotoSalesImportValidationException([
    '매출 표를 찾을 수 없습니다. Branch, 기기명(Device Name), 시간(Time), 금액(Amount) 열이 있는 Moers Excel을 사용하세요.',
  ]);
}

PhotoSalesImportWorkbook _parseTable(
  String sourceName,
  List<Object?> headerCells,
  Iterator<List<Object?>> remaining,
  int headerIndex,
) {
  final indexes = <String, int>{};
  for (var index = 0; index < headerCells.length; index += 1) {
    final canonical = _canonicalHeader(_cellText(headerCells[index]));
    if (canonical != null) indexes.putIfAbsent(canonical, () => index);
  }

  final missing = <String>[
    if (!indexes.containsKey('branch')) 'Branch(지점)',
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

  var rowIndex = headerIndex;
  while (remaining.moveNext()) {
    rowIndex++;
    final cells = remaining.current;
    final sourceRow = rowIndex + 1;
    Object? value(String key) {
      final index = indexes[key];
      return index == null || index >= cells.length ? null : cells[index];
    }

    final knownValues = indexes.keys.map(value).map(_cellText).toList();
    if (knownValues.every((text) => text.trim().isEmpty)) continue;

    final rawBranch = _cellText(value('branch')).trim();
    final branchCode = normalizePhotoSalesBranchCode(rawBranch);
    final deviceName = _cellText(value('device')).trim();
    final saleTime = _cellText(value('time')).trim();
    final rawAmount = value('amount');
    final amount = _parseWholeAmount(rawAmount);

    if (branchCode == null) {
      issues.add(
        '$sourceRow행: Branch "$rawBranch"를 POS 지점에 연결할 수 없습니다. '
        '지원값: BH, DI AN, LONG THANH, THẢO ĐIỀN, QUANG TRUNG, NOWZONE',
      );
    }
    if (deviceName.isEmpty) {
      issues.add('$sourceRow행: 기기명이 비어 있습니다.');
    }
    if (!_isValidSaleTime(saleTime)) {
      issues.add('$sourceRow행: 시간은 HH:mm 또는 HH:mm:ss 형식이어야 합니다.');
    }
    if (amount == null || amount < 0) {
      issues.add('$sourceRow행: 금액은 0 이상의 VND 정수여야 합니다.');
    }
    if (branchCode == null ||
        deviceName.isEmpty ||
        !_isValidSaleTime(saleTime) ||
        amount == null ||
        amount < 0) {
      continue;
    }
    if (amount == 0) {
      skippedZeroAmountCount += 1;
      continue;
    }

    if (rows.length >= photoSalesImportMaxRows) {
      throw const PhotoSalesImportValidationException([
        '한 번에 최대 $photoSalesImportMaxRows건의 매출만 변환할 수 있습니다.',
      ]);
    }
    rows.add(
      PhotoSalesImportRow(
        sourceRow: sourceRow,
        branchCode: branchCode,
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
    sourceSheetName: sourceName,
    skippedZeroAmountCount: skippedZeroAmountCount,
  );
}

String? _canonicalHeader(String value) {
  final normalized = value.trim().toLowerCase().replaceAll(
    RegExp(r'[\s_-]+'),
    '',
  );
  return switch (normalized) {
    'branch' || 'branchcode' || '지점' || '지점코드' => 'branch',
    '매장' || 'store' => 'store',
    '기기명' || 'devicename' => 'device',
    '기기id' || '기기아이디' || 'deviceid' => 'deviceId',
    '시간' || 'time' => 'time',
    '금액' || 'amount' => 'amount',
    '구분' || 'type' => 'type',
    _ => null,
  };
}

String? normalizePhotoSalesBranchCode(String value) {
  final normalized = value
      .trim()
      .toUpperCase()
      .replaceAll(RegExp('[ÀÁẢÃẠĂẮẰẲẴẶÂẤẦẨẪẬ]'), 'A')
      .replaceAll(RegExp('[ÈÉẺẼẸÊẾỀỂỄỆ]'), 'E')
      .replaceAll(RegExp('[ÌÍỈĨỊ]'), 'I')
      .replaceAll(RegExp('[ÒÓỎÕỌÔỐỒỔỖỘƠỚỜỞỠỢ]'), 'O')
      .replaceAll(RegExp('[ÙÚỦŨỤƯỨỪỬỮỰ]'), 'U')
      .replaceAll(RegExp('[ỲÝỶỸỴ]'), 'Y')
      .replaceAll('Đ', 'D')
      .replaceAll(RegExp(r'[^A-Z0-9]'), '');
  return switch (normalized) {
    'BH' || 'BIENHOA' => 'BH',
    'DA' || 'DIAN' => 'DA',
    'LT' || 'LONGTHANH' => 'LT',
    'TD' || 'THAODIEN' => 'TD',
    'QT' || 'QUANGTRUNG' => 'QT',
    'NZ' || 'NOWZONE' => 'NZ',
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

String _canonicalSaleTime(String value) {
  final match = RegExp(
    r'^(?:\d{4}-\d{2}-\d{2}[ T])?(\d{1,2}):(\d{2})(?::(\d{2}))?$',
  ).firstMatch(value)!;
  return '${match.group(1)!.padLeft(2, '0')}:'
      '${match.group(2)}:${match.group(3) ?? '00'}';
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
