import 'package:excel/excel.dart';

/// Builds the manual-import workbook using the same field names and order as
/// the MISA meInvoice cash-register API payload.
List<int> buildMisaPendingInvoiceWorkbook(List<Map<String, dynamic>> jobs) {
  if (jobs.isEmpty) {
    throw const FormatException('MISA_PENDING_EXPORT_EMPTY');
  }

  final workbook = Excel.createExcel();
  workbook.rename('Sheet1', 'InvoiceData');
  workbook.setDefaultSheet('InvoiceData');
  final invoices = workbook['InvoiceData'];
  invoices.appendRow(_invoiceHeaders.map(TextCellValue.new).toList());

  final details = workbook['OriginalInvoiceDetail'];
  details.appendRow(_detailHeaders.map(TextCellValue.new).toList());

  for (final job in jobs) {
    final refId = _text(job['misa_ref_id']).isNotEmpty
        ? _text(job['misa_ref_id'])
        : _text(job['id']);
    final buyer = _map(job['buyer_snapshot']);
    final lines = _maps(job['line_items_snapshot']);
    final totals = _totals(lines);
    final buyerLegalName = _firstText([
      buyer['unit_name'],
      buyer['customer_name'],
      'Nguoi mua khong lay hoa don',
    ]);
    final buyerFullName = _text(buyer['buyer_full_name']);
    final email = _text(buyer['email']);

    invoices.appendRow([
      TextCellValue(refId),
      TextCellValue(_text(job['invoice_series'])),
      TextCellValue('Hóa đơn GTGT khởi tạo từ máy tính tiền'),
      TextCellValue(_invoiceDate(job['created_at'])),
      TextCellValue('VND'),
      DoubleCellValue(1),
      TextCellValue(
        _text(job['payment_method_snapshot']).isEmpty
            ? 'Tien mat'
            : _text(job['payment_method_snapshot']),
      ),
      TextCellValue(_text(buyer['unit_code'])),
      TextCellValue(
        _firstText([buyer['tax_code'], buyer['tin_cic_household_head_id']]),
      ),
      TextCellValue(buyerLegalName),
      TextCellValue(buyerFullName),
      TextCellValue(_text(buyer['address'])),
      TextCellValue(email),
      TextCellValue(_text(buyer['phone'])),
      TextCellValue(buyerFullName.isNotEmpty ? buyerFullName : buyerLegalName),
      TextCellValue(_text(buyer['buyer_id'])),
      BoolCellValue(true),
      DoubleCellValue(0),
      DoubleCellValue(totals.amountWithoutVat),
      DoubleCellValue(totals.vatAmount),
      DoubleCellValue(totals.totalAmount),
      BoolCellValue(email.isNotEmpty),
      TextCellValue(buyerFullName.isNotEmpty ? buyerFullName : buyerLegalName),
      TextCellValue(email),
    ]);

    for (var index = 0; index < lines.length; index++) {
      final line = lines[index];
      final quantity = _number(
        line['quantity'],
        fallback: 1,
      ).clamp(1, double.infinity);
      final amountWithoutVat = _number(
        line['total_amount_ex_tax'] ?? line['AmountWithoutVAT'],
        fallback: _number(line['unit_price']) * quantity,
      );
      final vatAmount = _number(line['vat_amount'] ?? line['VATAmount']);
      final totalAmount = _number(
        line['paying_amount_inc_tax'] ?? line['AmountAfterTax'],
        fallback: amountWithoutVat + vatAmount,
      );
      details.appendRow([
        TextCellValue(refId),
        IntCellValue(1),
        IntCellValue(index + 1),
        IntCellValue(index + 1),
        TextCellValue(
          _firstText([
            line['order_item_id'],
            line['ItemCode'],
            'pos-line-${index + 1}',
          ]),
        ),
        TextCellValue(
          _firstText([
            line['display_name'],
            line['label'],
            line['ItemName'],
            'POS sale',
          ]),
        ),
        TextCellValue(
          _firstText([line['unit_name'], line['UnitName'], 'item']),
        ),
        DoubleCellValue(quantity.toDouble()),
        DoubleCellValue(amountWithoutVat / quantity),
        DoubleCellValue(0),
        DoubleCellValue(0),
        DoubleCellValue(amountWithoutVat),
        DoubleCellValue(amountWithoutVat),
        TextCellValue(_vatRateName(line)),
        DoubleCellValue(vatAmount),
        DoubleCellValue(totalAmount),
      ]);
    }
  }

  for (var index = 0; index < _invoiceHeaders.length; index++) {
    invoices.setColumnWidth(index, index >= 8 && index <= 15 ? 28 : 20);
  }
  for (var index = 0; index < _detailHeaders.length; index++) {
    details.setColumnWidth(index, index == 5 ? 32 : 20);
  }
  return workbook.encode()!;
}

const _invoiceHeaders = <String>[
  'RefID',
  'InvSeries',
  'InvoiceName',
  'InvDate',
  'CurrencyCode',
  'ExchangeRate',
  'PaymentMethodName',
  'BuyerCode',
  'BuyerTaxCode',
  'BuyerLegalName',
  'BuyerFullName',
  'BuyerAddress',
  'BuyerEmail',
  'BuyerPhoneNumber',
  'ContactName',
  'AccountObjectIdentificationNumber',
  'IsInvoiceCalculatingMachine',
  'DiscountRate',
  'TotalAmountWithoutVAT',
  'TotalVATAmount',
  'TotalAmount',
  'IsSendEmail',
  'ReceiverName',
  'ReceiverEmail',
];

const _detailHeaders = <String>[
  'RefID',
  'ItemType',
  'LineNumber',
  'SortOrder',
  'ItemCode',
  'ItemName',
  'UnitName',
  'Quantity',
  'UnitPrice',
  'DiscountRate',
  'DiscountAmount',
  'Amount',
  'AmountWithoutVAT',
  'VATRateName',
  'VATAmount',
  'AmountAfterTax',
];

({double amountWithoutVat, double vatAmount, double totalAmount}) _totals(
  List<Map<String, dynamic>> lines,
) {
  var amountWithoutVat = 0.0;
  var vatAmount = 0.0;
  var totalAmount = 0.0;
  for (final line in lines) {
    final amount = _number(
      line['total_amount_ex_tax'] ?? line['AmountWithoutVAT'],
    );
    final vat = _number(line['vat_amount'] ?? line['VATAmount']);
    final total = _number(
      line['paying_amount_inc_tax'] ?? line['AmountAfterTax'],
      fallback: amount + vat,
    );
    amountWithoutVat += amount;
    vatAmount += vat;
    totalAmount += total;
  }
  return (
    amountWithoutVat: amountWithoutVat,
    vatAmount: vatAmount,
    totalAmount: totalAmount,
  );
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

String _invoiceDate(Object? value) {
  final date = DateTime.tryParse(
    _text(value),
  )?.toUtc().add(const Duration(hours: 7));
  if (date == null) return '';
  return '${date.year.toString().padLeft(4, '0')}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
}

String _vatRateName(Map<String, dynamic> line) {
  final existing = _text(line['VATRateName']);
  if (existing.isNotEmpty) return existing;
  final rate = _number(line['vat_rate']);
  return '${rate.round()}%';
}
