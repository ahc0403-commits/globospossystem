import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:excel/excel.dart';
import 'package:archive/archive.dart';
import 'package:uuid/uuid.dart';
import 'sales_export_validation.dart';
import 'misa_description_normalization.dart';
export 'sales_export_validation.dart';

// MISA's discrepancy warning compares VND amounts after rounding to whole dong.
bool isMisaVatConsistent(double supply, double rate, double vat) =>
    supply.isFinite &&
    rate.isFinite &&
    vat.isFinite &&
    supply >= 0 &&
    rate >= 0 &&
    rate <= 100 &&
    vat >= 0 &&
    _roundVnd(supply * rate / 100) == _roundVnd(vat);

bool isMisaVatSummaryConsistent(
  Iterable<({double supply, double rate, double vat})> lines,
) {
  final totals = <double, ({double supply, double vat})>{};
  for (final line in lines) {
    final prev = totals[line.rate] ?? (supply: 0.0, vat: 0.0);
    totals[line.rate] = (
      supply: prev.supply + line.supply,
      vat: prev.vat + line.vat,
    );
  }
  return totals.entries.every(
    (entry) =>
        isMisaVatConsistent(entry.value.supply, entry.key, entry.value.vat),
  );
}

bool isMisaLineTotalConsistent(
  double quantity,
  double unitPrice,
  double totalAmount,
) =>
    quantity.isFinite &&
    unitPrice.isFinite &&
    totalAmount.isFinite &&
    quantity > 0 &&
    unitPrice >= 0 &&
    totalAmount >= 0 &&
    _roundVnd(quantity * unitPrice) == _roundVnd(totalAmount);

({double supplyAmount, double vatAmount}) splitMisaGrossAmount(
  double gross,
  double vatRate,
) {
  final safeGross = gross.isFinite && gross >= 0 ? gross : 0.0;
  final safeRate = vatRate.isFinite && vatRate >= 0 && vatRate <= 100
      ? vatRate
      : 0.0;

  // Source amounts are stored to two decimals, but use progressively finer
  // precision for a half-dong boundary. This keeps the original gross while
  // making MISA's rounded VAT comparison exact.
  for (final scale in const [100, 1000, 10000, 100000, 1000000]) {
    final grossUnits = (safeGross * scale).round();
    if ((grossUnits / scale - safeGross).abs() > 0.5 / scale) continue;
    final idealSupplyUnits = (grossUnits * 100 / (100 + safeRate)).round();
    for (var offset = 0; offset <= 10; offset++) {
      for (final supplyUnits
          in offset == 0
              ? [idealSupplyUnits]
              : [idealSupplyUnits - offset, idealSupplyUnits + offset]) {
        if (supplyUnits < 0 || supplyUnits > grossUnits) continue;
        final supply = supplyUnits / scale;
        final vat = (grossUnits - supplyUnits) / scale;
        if (isMisaVatConsistent(supply, safeRate, vat)) {
          return (supplyAmount: supply, vatAmount: vat);
        }
      }
    }
  }

  final supply = safeGross / (1 + safeRate / 100);
  return (supplyAmount: supply, vatAmount: supply * safeRate / 100);
}

/// Builds the 17-column MISA import worksheet used by POS operations.
///
/// Restaurant rows retain the sold item, quantity and tax snapshot.
/// The separate POS Ledger sheet links these rows to their source identities.
List<int> buildMisaPendingInvoiceWorkbook(
  List<Map<String, dynamic>> jobs, {
  String? generationId,
  List<Map<String, dynamic>>? descriptionNormalizations,
}) {
  if (jobs.isEmpty) {
    throw const FormatException('MISA_PENDING_EXPORT_EMPTY');
  }

  final issues = validateSalesExportJobs(jobs);
  if (issues.isNotEmpty) throw SalesExportValidationException(issues);
  final ordered = [...jobs]
    ..sort((a, b) {
      final time = _saleDate(a).compareTo(_saleDate(b));
      return time != 0
          ? time
          : '${a['source_system']}:${a['receipt_id'] ?? a['id']}'.compareTo(
              '${b['source_system']}:${b['receipt_id'] ?? b['id']}',
            );
    });
  final workbook = Excel.createExcel();
  workbook.rename('Sheet1', 'Hóa đơn GTGT');
  workbook.setDefaultSheet('Hóa đơn GTGT');
  final sheet = workbook['Hóa đơn GTGT'];
  final ledger = workbook['POS Ledger'];
  final mapping = workbook['Invoice Mapping'];
  final deliveryRows = <List<CellValue>>[];
  final descriptions = <Map<String, dynamic>>[];
  mapping.appendRow(
    const [
      'invoice_sequence',
      'excel_row',
      'source_order_item_id',
      'invoice_profile_id',
      'invoice_approval_type',
      'invoice_mapping_version',
      'invoice_effective_from',
      'invoice_effective_to',
      'invoice_store_id',
      'invoice_source_reference',
      'source_unit_price',
      'misa_unit_price',
      'misa_discount_amount',
    ].map(TextCellValue.new).toList(),
  );
  final storeTotals =
      <
        String,
        ({String name, String code, String entity, double gross, int receipts})
      >{};
  double sourceTotal = 0;
  var roundedTotal = 0;
  final sourceItems = <String>{};
  ledger.appendRow(
    const [
      'version',
      'business_date',
      'tax_entity_id',
      'source_system',
      'receipt_id',
      'receipt_number',
      'order_item_id',
      'menu_item_id',
      'invoice_sequence',
      'excel_row',
      'source_hash',
      'snapshot_version',
      'line_hash',
      'payment_methods',
      'store_id',
      'store_code',
      'store_name',
      'store_name_origin',
    ].map(TextCellValue.new).toList(),
  );

  for (final text in _instructions) {
    sheet.appendRow([TextCellValue(text)]);
  }
  // Keep the template's seventh row physically present. An empty row without
  // a cell is dropped by the Excel encoder and shifts the required headers.
  sheet.appendRow([TextCellValue('')]);
  sheet.appendRow(_headers.map(TextCellValue.new).toList());

  for (var invoiceIndex = 0; invoiceIndex < ordered.length; invoiceIndex++) {
    final job = ordered[invoiceIndex];
    final buyer = _map(job['buyer_snapshot']);
    final emails = normalizeMisaEmailAddresses(buyer['email']);
    final importEmail = emails.isEmpty ? '' : emails.first;
    if (emails.length > 1) {
      deliveryRows.add([
        TextCellValue((invoiceIndex + 1).toString()),
        TextCellValue(importEmail),
        TextCellValue(emails.join(';')),
      ]);
    }
    final lines = _maps(job['line_items_snapshot']);
    final isPhoto = _text(job['source_system']) == 'photo_objet_moers';
    final legalName = _firstText([
      buyer['unit_name'],
      buyer['customer_name'],
      'Bán cho người tiêu dùng',
    ]);
    final buyerName = job.containsKey('misa_buyer_person_name')
        ? _text(job['misa_buyer_person_name'])
        : _firstText([
            buyer['buyer_full_name'],
            legalName,
            'Bán cho người tiêu dùng',
          ]);

    final preparedLines = _prepareMisaLines(lines, isPhoto: isPhoto);
    if (!isMisaVatSummaryConsistent(
      preparedLines.map(
        (p) => (
          supply: p.amounts.supplyAmount,
          rate: p.amounts.vatRate,
          vat: p.amounts.vatAmount,
        ),
      ),
    )) {
      throw const FormatException('MISA_EXPORT_SOURCE_VAT_SUMMARY_MISMATCH');
    }
    final storeId = _text(job['store_id']);
    final storeKey = '${_text(job['tax_entity_id'])}:$storeId';
    final previous = storeTotals[storeKey];
    storeTotals[storeKey] = (
      name: _text(job['store_name']),
      code: _text(job['store_code']),
      entity: _text(job['tax_entity_id']),
      gross:
          (previous?.gross ?? 0) +
          preparedLines.fold<double>(
            0,
            (s, l) => s + l.amounts.supplyAmount + l.amounts.vatAmount,
          ),
      receipts: (previous?.receipts ?? 0) + 1,
    );
    for (var lineIndex = 0; lineIndex < preparedLines.length; lineIndex++) {
      final prepared = preparedLines[lineIndex];
      final line = prepared.line;
      final amounts = prepared.amounts;
      final originalDescription = _firstText([
        line['invoice_name_vi'],
        line['display_name'],
        line['label'],
        line['ItemName'],
        isPhoto ? 'Dịch vụ chụp ảnh' : 'Món ăn',
      ]);
      final description = isPhoto
          ? null
          : normalizeMisaDescription(originalDescription);
      sheet.appendRow([
        TextCellValue((invoiceIndex + 1).toString()),
        if (lineIndex == 0) ...[
          TextCellValue(_invoiceDate(_saleDate(job))),
          TextCellValue(legalName),
          TextCellValue(
            _firstText([buyer['tax_code'], buyer['tin_cic_household_head_id']]),
          ),
          TextCellValue(_text(buyer['address'])),
          TextCellValue(buyerName),
          TextCellValue(importEmail),
          TextCellValue(_text(buyer['phone'])),
          TextCellValue(_text(buyer['buyer_id'])),
          TextCellValue(
            misaPaymentCode(
              job['payment_method_snapshot'] ?? (isPhoto ? 'CASH' : null),
            ),
          ),
        ] else
          ...List<CellValue?>.filled(9, null),
        TextCellValue(description?.text ?? originalDescription),
        TextCellValue(
          _firstText([line['misa_unit_name'], isPhoto ? 'Lần' : 'Phần']),
        ),
        DoubleCellValue(prepared.quantity),
        DoubleCellValue(amounts.unitPrice),
        DoubleCellValue(amounts.supplyAmount),
        DoubleCellValue(amounts.vatRate),
        DoubleCellValue(amounts.vatAmount),
      ]);
      final rowNumber = sheet.maxRows;
      if (description?.changed == true) {
        descriptions.add({
          'policy': misaDescriptionPolicy,
          'invoice_sequence': invoiceIndex + 1,
          'excel_row': rowNumber,
          'source_system': _text(job['source_system']),
          'receipt_id': _text(job['receipt_id'] ?? job['id']),
          'order_item_id': _text(line['order_item_id']),
          'menu_item_id': _text(line['menu_item_id']),
          'original_description': originalDescription,
          'export_description': description!.text,
          'removed_graphemes': description.removals,
        });
      }
      final sourceHash = _firstText([
        job['source_hash'],
        sha256.convert(utf8.encode(jsonEncode(job))).toString(),
      ]);
      final sourceItem = _firstText([
        line['source_order_item_id'],
        _text(line['order_item_id']).split(':').first,
      ]);
      sourceItems.add(
        '${job['source_system']}:${job['receipt_id']}:$sourceItem',
      );
      sourceTotal += amounts.supplyAmount + amounts.vatAmount;
      roundedTotal += amounts.supplyAmount.round() + amounts.vatAmount.round();
      mapping.appendRow([
        TextCellValue((invoiceIndex + 1).toString()),
        IntCellValue(rowNumber),
        TextCellValue(sourceItem),
        ...[
          'invoice_profile_id',
          'invoice_approval_type',
          'invoice_mapping_version',
          'invoice_effective_from',
          'invoice_effective_to',
          'invoice_store_id',
          'invoice_source_reference',
        ].map((k) => TextCellValue(_text(line[k]))),
        DoubleCellValue(_number(line['unit_price'])),
        DoubleCellValue(
          _number(line['misa_unit_price'], fallback: amounts.unitPrice),
        ),
        DoubleCellValue(_number(line['misa_discount_amount'])),
      ]);
      ledger.appendRow([
        IntCellValue(3),
        TextCellValue(
          _saleDate(job)
              .toUtc()
              .add(const Duration(hours: 7))
              .toIso8601String()
              .substring(0, 10),
        ),
        TextCellValue(_text(job['tax_entity_id'])),
        TextCellValue(_text(job['source_system'])),
        TextCellValue(_text(job['receipt_id'] ?? job['id'])),
        TextCellValue(_text(job['receipt_number'])),
        TextCellValue(_text(line['order_item_id'])),
        TextCellValue(_text(line['menu_item_id'])),
        IntCellValue(invoiceIndex + 1),
        IntCellValue(rowNumber),
        TextCellValue(sourceHash),
        IntCellValue(_number(job['snapshot_version'], fallback: 1).toInt()),
        TextCellValue(sha256.convert(utf8.encode(jsonEncode(line))).toString()),
        TextCellValue(jsonEncode(job['payment_methods'] ?? [])),
        TextCellValue(_text(job['store_id'])),
        TextCellValue(_text(job['store_code'])),
        TextCellValue(_text(job['store_name'])),
        TextCellValue(_text(job['store_name_origin'] ?? 'current_registry')),
      ]);
    }
  }

  final stores = workbook['Store Reconciliation'];
  stores.appendRow(
    [
      'tax_entity_id',
      'store_id',
      'store_code',
      'store_name',
      'receipt_count',
      'source_gross',
    ].map(TextCellValue.new).toList(),
  );
  for (final key in storeTotals.keys.toList()..sort()) {
    final value = storeTotals[key]!;
    stores.appendRow([
      TextCellValue(value.entity),
      TextCellValue(key.substring(value.entity.length + 1)),
      TextCellValue(value.code),
      TextCellValue(value.name),
      IntCellValue(value.receipts),
      DoubleCellValue(value.gross),
    ]);
  }
  final contract = workbook['Export Contract'];
  for (final entry in {
    'format_version': 'pos-sales-xlsx-v4',
    'ledger_version': '3',
    if (ordered.any((j) => j['source_system'] != 'photo_objet_moers'))
      'description_normalization_policy': misaDescriptionPolicy,
    'generation_id': generationId ?? const Uuid().v4(),
    'content_sha256': sha256
        .convert(utf8.encode(jsonEncode(ordered)))
        .toString(),
    'receipt_count': ordered.length.toString(),
    'source_item_count': sourceItems.length.toString(),
    'export_line_count': (sheet.maxRows - 8).toString(),
    'source_gross': sourceTotal.toStringAsFixed(2),
    'rounded_line_gross': roundedTotal.toString(),
    'rounding_difference': (sourceTotal - roundedTotal).toStringAsFixed(2),
    'rounding_rule': 'positive HALF_UP per supply and VAT line',
    'continuation_rule': 'A text; B:J first line only; inherit in consumer',
  }.entries) {
    contract.appendRow([TextCellValue(entry.key), TextCellValue(entry.value)]);
  }
  if (descriptions.isNotEmpty) {
    const headers = [
      'policy',
      'invoice_sequence',
      'excel_row',
      'source_system',
      'receipt_id',
      'order_item_id',
      'menu_item_id',
      'original_description',
      'export_description',
      'removed_graphemes',
    ];
    final audit = workbook['Description Normalization'];
    audit.appendRow(headers.map(TextCellValue.new).toList());
    for (final row in descriptions) {
      audit.appendRow([
        for (final key in headers)
          TextCellValue(
            key == 'removed_graphemes' ? jsonEncode(row[key]) : '${row[key]}',
          ),
      ]);
    }
  }
  descriptionNormalizations?.addAll(descriptions);
  if (deliveryRows.isNotEmpty) {
    final delivery = workbook['Email Delivery'];
    delivery.appendRow(_emailDeliveryHeaders.map(TextCellValue.new).toList());
    for (final row in deliveryRows) {
      delivery.appendRow(row);
    }
    delivery.setColumnWidth(0, 18);
    delivery.setColumnWidth(1, 36);
    delivery.setColumnWidth(2, 80);
  }
  validateMisaEmailDeliveryWorkbook(workbook);
  for (var index = 0; index < _headers.length; index++) {
    sheet.setColumnWidth(index, switch (index) {
      2 || 4 || 5 || 10 => 28,
      _ => 18,
    });
  }
  // excel 4 writes the template's A1 dimension unchanged. Read-only consumers
  // trust that bound and would otherwise see only one row. Set actual bounds.
  final archive = ZipDecoder().decodeBytes(workbook.encode()!);
  final fixed = Archive();
  for (final file in archive.files) {
    if (!file.name.startsWith('xl/worksheets/sheet') ||
        !file.name.endsWith('.xml')) {
      fixed.addFile(file);
      continue;
    }
    var xml = utf8.decode(file.content as List<int>);
    var maxColumn = 1, maxRow = 1;
    for (final cell in RegExp(
      r'<c\b[^>]*\br="([A-Z]+)([0-9]+)"',
    ).allMatches(xml)) {
      var col = 0;
      for (final c in cell.group(1)!.codeUnits) {
        col = col * 26 + c - 64;
      }
      if (col > maxColumn) maxColumn = col;
      final row = int.parse(cell.group(2)!);
      if (row > maxRow) maxRow = row;
    }
    var colName = '';
    for (var c = maxColumn; c > 0; c = (c - 1) ~/ 26) {
      colName = String.fromCharCode(65 + (c - 1) % 26) + colName;
    }
    xml = xml.replaceFirst(
      RegExp(r'<dimension\b[^>]*/>'),
      '<dimension ref="A1:$colName$maxRow"/>',
    );
    final bytes = utf8.encode(xml);
    fixed.addFile(ArchiveFile(file.name, bytes.length, bytes));
  }
  return ZipEncoder().encode(fixed)!;
}

const _emailDeliveryHeaders = [
  'Invoice sequence',
  'Import email',
  'Delivery emails',
];

/// Checks invoice-level links while allowing A to repeat on item continuations.
/// Errors identify the sequence/row without including customer email addresses.
void validateMisaEmailDeliveryWorkbook(Excel workbook) {
  final invoiceSheet = workbook.tables['Hóa đơn GTGT'];
  if (invoiceSheet == null) {
    throw const FormatException('MISA_EMAIL_INVOICE_SHEET_REQUIRED');
  }
  String cell(List<Data?> row, int index) =>
      index < row.length ? row[index]?.value?.toString() ?? '' : '';
  Never reject(String code, String sequence, int row) => throw FormatException(
    '$code: invoice_sequence=$sequence, excel_row=$row',
  );
  final invoices = <String, String>{};
  String? previousSequence;
  final invoiceRows = invoiceSheet.rows;
  for (var index = 8; index < invoiceRows.length; index++) {
    final row = invoiceRows[index];
    final sequence = cell(row, 0);
    if (sequence.isEmpty || row[0]?.value is! TextCellValue) {
      reject('MISA_EMAIL_INVOICE_SEQUENCE_TEXT_REQUIRED', sequence, index + 1);
    }
    if (sequence == previousSequence) {
      if (row.skip(1).take(9).any((c) => _text(c?.value).isNotEmpty)) {
        reject('MISA_EMAIL_DUPLICATE_INVOICE_SEQUENCE', sequence, index + 1);
      }
      continue;
    }
    if (invoices.containsKey(sequence)) {
      reject('MISA_EMAIL_DUPLICATE_INVOICE_SEQUENCE', sequence, index + 1);
    }
    final email = cell(row, 6);
    if (email.isNotEmpty && !isValidMisaEmailAddress(email)) {
      reject('MISA_EMAIL_IMPORT_EMAIL_INVALID', sequence, index + 1);
    }
    invoices[sequence] = email;
    previousSequence = sequence;
  }
  final delivery = workbook.tables['Email Delivery'];
  if (delivery == null) return;
  final rows = delivery.rows;
  if (delivery.maxColumns != 3 ||
      rows.isEmpty ||
      List.generate(3, (i) => cell(rows.first, i)).join('\n') !=
          _emailDeliveryHeaders.join('\n')) {
    throw const FormatException('MISA_EMAIL_DELIVERY_HEADERS_INVALID');
  }
  final seen = <String>{};
  for (var index = 1; index < rows.length; index++) {
    final row = rows[index];
    final sequence = cell(row, 0);
    if (sequence.isEmpty || row[0]?.value is! TextCellValue) {
      reject('MISA_EMAIL_INVOICE_SEQUENCE_TEXT_REQUIRED', sequence, index + 1);
    }
    if (!seen.add(sequence)) {
      reject('MISA_EMAIL_DUPLICATE_DELIVERY_SEQUENCE', sequence, index + 1);
    }
    if (!invoices.containsKey(sequence)) {
      reject('MISA_EMAIL_UNKNOWN_INVOICE_SEQUENCE', sequence, index + 1);
    }
    final importEmail = cell(row, 1);
    if (importEmail != invoices[sequence]) {
      reject('MISA_EMAIL_IMPORT_EMAIL_MISMATCH', sequence, index + 1);
    }
    final rawEmails = cell(row, 2);
    if (rawEmails.length > 255) {
      reject('MISA_EXPORT_DELIVERY_EMAILS_TOO_LONG_255', sequence, index + 1);
    }
    final emails = normalizeMisaEmailAddresses(rawEmails);
    if (importEmail.isEmpty || !emails.contains(importEmail)) {
      reject(
        'MISA_EMAIL_IMPORT_EMAIL_MISSING_FROM_DELIVERY',
        sequence,
        index + 1,
      );
    }
    if (emails.length < 2 ||
        emails.join(';') != rawEmails ||
        emails.any((email) => !isValidMisaEmailAddress(email))) {
      reject('MISA_EMAIL_DELIVERY_LIST_INVALID', sequence, index + 1);
    }
  }
}

List<
  ({
    Map<String, dynamic> line,
    double quantity,
    ({double unitPrice, double supplyAmount, double vatRate, double vatAmount})
    amounts,
  })
>
_prepareMisaLines(List<Map<String, dynamic>> lines, {required bool isPhoto}) {
  if (lines.isEmpty) throw const FormatException('MISA_EXPORT_EMPTY_LINES');
  return lines
      .map((line) {
        if (!isPhoto &&
            (_text(line['invoice_name_vi']).isEmpty ||
                _text(line['misa_unit_name']).isEmpty ||
                _text(line['order_item_id']).isEmpty)) {
          throw const FormatException('MISA_APPROVED_ITEM_METADATA_REQUIRED');
        }
        final quantity = salesExportNumber(line['quantity'])!;
        final rate = isPhoto ? 8.0 : salesExportNumber(line['vat_rate'])!;
        if (!quantity.isFinite ||
            quantity <= 0 ||
            !rate.isFinite ||
            rate < 0 ||
            rate > 100) {
          throw const FormatException('MISA_EXPORT_INVALID_LINE');
        }
        final photoSplit = isPhoto
            ? splitMisaGrossAmount(
                salesExportNumber(line['paying_amount_inc_tax'])!,
                rate,
              )
            : null;
        final supply =
            photoSplit?.supplyAmount ?? _number(line['total_amount_ex_tax']);
        final vat = photoSplit?.vatAmount ?? _number(line['vat_amount']);
        final unitPrice = supply / quantity;
        if (!isMisaLineTotalConsistent(quantity, unitPrice, supply) ||
            !isMisaVatConsistent(supply, rate, vat)) {
          throw const FormatException('MISA_EXPORT_SOURCE_AMOUNT_MISMATCH');
        }
        return (
          line: isPhoto
              ? {
                  ...line,
                  'invoice_approval_type': 'source_contract',
                  'invoice_mapping_version': 'photo-service-v1',
                  'invoice_source_reference':
                      'POS manual Photo import / 8% service contract',
                }
              : line,
          quantity: quantity,
          amounts: (
            unitPrice: unitPrice,
            supplyAmount: supply,
            vatRate: rate,
            vatAmount: vat,
          ),
        );
      })
      .toList(growable: false);
}

const _instructions = <String>[
  'File mẫu danh sách hóa đơn để nhập vào phần mềm ',
  'Hướng dẫn:',
  '- Điền dữ liệu hóa đơn cần lập trên phần mềm vào các cột tương ứng trên file này',
  '- Các cột có dấu (*) là những cột bắt buộc',
  '- Nếu muốn nhập thêm thông tin khác, người dùng có thể tự thêm cột trên file này',
  '- Các dòng dữ liệu phía dưới chỉ là ví dụ minh họa',
];

const _headers = <String>[
  'Số thứ tự hóa đơn (*)',
  'Ngày hóa đơn',
  'Tên đơn vị mua hàng',
  'Mã số thuế',
  'Địa chỉ',
  'Người mua hàng',
  'Email',
  'Số điện thoại',
  'Căn cước công dân',
  'Hình thức thanh toán (*)',
  'Tên hàng hóa/dịch vụ (*)',
  'ĐVT',
  'Số lượng',
  'Đơn giá',
  'Thành tiền',
  'Thuế suất GTGT (%)',
  'Tiền thuế GTGT',
];

String misaPaymentCode(Object? value) {
  final normalized = _text(
    value,
  ).toLowerCase().replaceAll(' ', '').replaceAll('_', '');
  return switch (normalized) {
    'tm' || 'cash' || 'tiềnmặt' || 'tienmat' => 'TM',
    'ck' || 'banktransfer' || 'chuyểnkhoản' || 'chuyenkhoan' => 'CK',
    'tm/ck' => 'TM/CK',
    'creditcard' || 'card' || 'thẻ' || 'thẻquốctế' => 'Thẻ quốc tế',
    'atm' || 'thẻatm' => 'Thẻ ATM',
    'epay' ||
    'pay' ||
    'other' ||
    'momo' ||
    'zalopay' ||
    'shopeepay' ||
    'víđiệntử' => 'Ví điện tử',
    'vnpay' => 'VNPAY',
    'voucher' => 'Voucher',
    'creditsale' || 'chưathutiền' => 'Chưa thu tiền',
    _ => _misaMixedPaymentCode(value),
  };
}

String _misaMixedPaymentCode(Object? value) {
  final parts = _text(value).split('/');
  if (parts.length < 2) {
    throw const FormatException('MISA_PAYMENT_MAPPING_REQUIRED');
  }
  final labels = parts.map(misaPaymentCode).toSet().toList()..sort();
  if (labels.length == 2 && labels.contains('TM') && labels.contains('CK')) {
    return 'TM/CK';
  }
  return labels.join('/');
}

Map<String, dynamic> _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : const <String, dynamic>{};

List<Map<String, dynamic>> _maps(Object? value) => value is List
    ? value
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList()
    : const <Map<String, dynamic>>[];

String _text(Object? value) => value?.toString().trim() ?? '';

String _firstText(List<Object?> values) {
  for (final value in values) {
    final text = _text(value);
    if (text.isNotEmpty) return text;
  }
  return '';
}

double _number(Object? value, {double fallback = 0}) {
  if (value is num) return value.toDouble();
  return double.tryParse(_text(value)) ?? fallback;
}

int _roundVnd(double value) => value.round();

DateTime _date(Object? value) =>
    DateTime.tryParse(_text(value)) ?? DateTime.fromMillisecondsSinceEpoch(0);

DateTime _saleDate(Map<String, dynamic> job) {
  if (_text(job['source_system']) == 'photo_objet_moers') {
    final source = _map(job['source_snapshot']);
    final rawSaleDate = _text(source['sale_date']);
    if (rawSaleDate.isNotEmpty) return _date(rawSaleDate);
  }
  return _date(job['created_at']);
}

String _invoiceDate(Object? value) {
  final parsed = value is DateTime ? value : _date(value);
  final date = parsed.toUtc().add(const Duration(hours: 7));
  return '${date.day.toString().padLeft(2, '0')}/${date.month.toString().padLeft(2, '0')}/${date.year.toString().padLeft(4, '0')}';
}
