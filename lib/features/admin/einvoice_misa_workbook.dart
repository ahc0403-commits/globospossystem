import 'package:excel/excel.dart';

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

/// Builds the one-sheet MISA desktop import workbook used by POS operations.
///
/// Every receipt is normalized to one VAT-inclusive service row per tax rate.
/// This preserves the paid total while keeping MISA's quantity, amount, and
/// VAT arithmetic internally consistent.
List<int> buildMisaPendingInvoiceWorkbook(List<Map<String, dynamic>> jobs) {
  if (jobs.isEmpty) {
    throw const FormatException('MISA_PENDING_EXPORT_EMPTY');
  }

  final ordered = [...jobs]
    ..sort((a, b) => _saleDate(a).compareTo(_saleDate(b)));
  final workbook = Excel.createExcel();
  workbook.rename('Sheet1', 'Hóa đơn GTGT');
  workbook.setDefaultSheet('Hóa đơn GTGT');
  final sheet = workbook['Hóa đơn GTGT'];

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
    for (final prepared in preparedLines) {
      final line = prepared.line;
      final amounts = prepared.amounts;
      sheet.appendRow([
        IntCellValue(invoiceIndex + 1),
        TextCellValue(_invoiceDate(_saleDate(job))),
        TextCellValue(legalName),
        TextCellValue(
          _firstText([buyer['tax_code'], buyer['tin_cic_household_head_id']]),
        ),
        TextCellValue(_text(buyer['address'])),
        TextCellValue(buyerName),
        TextCellValue(_text(buyer['email'])),
        TextCellValue(_text(buyer['phone'])),
        TextCellValue(_text(buyer['buyer_id'])),
        TextCellValue(_paymentCode(job['payment_method_snapshot'])),
        TextCellValue(
          _firstText([
            line['display_name'],
            line['label'],
            line['ItemName'],
            isPhoto ? 'Dịch vụ chụp ảnh' : 'Món ăn',
          ]),
        ),
        TextCellValue(
          _firstText([line['misa_unit_name'], isPhoto ? 'Lần' : 'Phần']),
        ),
        const DoubleCellValue(1),
        DoubleCellValue(amounts.unitPrice),
        DoubleCellValue(amounts.supplyAmount),
        DoubleCellValue(amounts.vatRate),
        DoubleCellValue(amounts.vatAmount),
      ]);
    }
  }

  for (var index = 0; index < _headers.length; index++) {
    sheet.setColumnWidth(index, switch (index) {
      2 || 4 || 5 || 10 => 28,
      _ => 18,
    });
  }
  return workbook.encode()!;
}

List<
  ({
    Map<String, dynamic> line,
    ({double unitPrice, double supplyAmount, double vatRate, double vatAmount})
    amounts,
  })
>
_prepareMisaLines(List<Map<String, dynamic>> lines, {required bool isPhoto}) {
  final grouped = <double, List<Map<String, dynamic>>>{};
  for (final line in lines) {
    final rawRate = isPhoto ? 8.0 : _restaurantVatRate(line);
    final rate = rawRate.isFinite && rawRate >= 0 && rawRate <= 100
        ? rawRate
        : 0.0;
    grouped.putIfAbsent(rate, () => []).add(line);
  }

  return grouped.entries
      .map((entry) {
        final groupedLines = entry.value;
        final gross = groupedLines.fold<double>(
          0,
          (total, line) =>
              total + _lineGross(line, entry.key, isPhoto: isPhoto),
        );
        final split = splitMisaGrossAmount(gross, entry.key);
        final first = groupedLines.first;
        final line = <String, dynamic>{
          ...first,
          'display_name': isPhoto
              ? _firstText([first['display_name'], 'Dịch vụ chụp ảnh'])
              : groupedLines.length == 1
              ? _firstText([
                  first['display_name'],
                  first['label'],
                  'Dịch vụ ăn uống',
                ])
              : 'Dịch vụ ăn uống',
          'misa_unit_name': 'Lần',
        };
        return (
          line: line,
          amounts: (
            unitPrice: split.supplyAmount,
            supplyAmount: split.supplyAmount,
            vatRate: entry.key,
            vatAmount: split.vatAmount,
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

double _restaurantVatRate(Map<String, dynamic> line) {
  final supply = _number(
    line['total_amount_ex_tax'] ?? line['AmountWithoutVAT'],
    fallback:
        _number(line['unit_price']) * _number(line['quantity'], fallback: 1),
  );
  final vat = _number(line['vat_amount'] ?? line['VATAmount']);
  return _number(
    line['vat_rate'],
    fallback: supply == 0 ? 0 : vat / supply * 100,
  );
}

double _lineGross(
  Map<String, dynamic> line,
  double vatRate, {
  required bool isPhoto,
}) {
  final quantity = _number(line['quantity'], fallback: 1).clamp(1, 999999);
  if (isPhoto) {
    return _number(
      line['paying_amount_inc_tax'] ?? line['AmountAfterTax'],
      fallback: _number(line['unit_price']) * quantity,
    );
  }
  final suppliedGross = line['paying_amount_inc_tax'] ?? line['AmountAfterTax'];
  if (suppliedGross != null) return _number(suppliedGross);
  final supply = _number(
    line['total_amount_ex_tax'] ?? line['AmountWithoutVAT'],
    fallback: _number(line['unit_price']) * quantity,
  );
  final rawVat = line['vat_amount'] ?? line['VATAmount'];
  final vat = rawVat == null ? supply * vatRate / 100 : _number(rawVat);
  return supply + vat;
}

String _paymentCode(Object? value) {
  final normalized = _text(value).toLowerCase();
  if (normalized == 'tm' || normalized == 'ck') return normalized.toUpperCase();
  if (normalized.contains('cash') ||
      normalized.contains('tiền mặt') ||
      normalized.contains('tien mat')) {
    return 'TM';
  }
  if (normalized.contains('card') || normalized.contains('thẻ')) return 'CK';
  if (normalized.contains('transfer') || normalized.contains('chuyển khoản')) {
    return 'CK';
  }
  return normalized.isEmpty ? 'TM' : _text(value);
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
