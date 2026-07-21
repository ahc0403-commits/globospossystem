import 'package:excel/excel.dart';

class RedInvoiceLineItem {
  const RedInvoiceLineItem({
    required this.id,
    required this.name,
    required this.quantity,
    required this.unitPrice,
    required this.vatRate,
    required this.amountWithoutVat,
    required this.vatAmount,
    required this.amountAfterTax,
  });

  factory RedInvoiceLineItem.fromJson(Map<String, dynamic> json) {
    return RedInvoiceLineItem(
      id: json['order_item_id']?.toString() ?? '',
      name: json['display_name']?.toString() ?? 'Item',
      quantity: _toDouble(json['quantity']),
      unitPrice: _toDouble(json['unit_price']),
      vatRate: _toDouble(json['vat_rate']),
      amountWithoutVat: _toDouble(json['total_amount_ex_tax']),
      vatAmount: _toDouble(json['vat_amount']),
      amountAfterTax: _toDouble(json['paying_amount_inc_tax']),
    );
  }

  final String id;
  final String name;
  final double quantity;
  final double unitPrice;
  final double vatRate;
  final double amountWithoutVat;
  final double vatAmount;
  final double amountAfterTax;
}

class RedInvoiceIntake {
  const RedInvoiceIntake({
    required this.id,
    required this.orderId,
    required this.storeId,
    required this.storeName,
    required this.meInvoiceJobId,
    required this.invoiceSeries,
    required this.receiptIds,
    required this.saleAt,
    required this.grossAmount,
    required this.paymentMethod,
    required this.source,
    required this.status,
    required this.buyerTaxCode,
    required this.buyerUnitCode,
    required this.buyerLegalName,
    required this.buyerFullName,
    required this.buyerAddress,
    required this.buyerEmail,
    required this.buyerEmailCc,
    required this.buyerPhone,
    required this.buyerId,
    required this.sourceNote,
    required this.attachmentUrls,
    required this.requestedAt,
    required this.exportBatchId,
    required this.lineItems,
    required this.meInvoiceStatus,
  });

  factory RedInvoiceIntake.fromJson(Map<String, dynamic> json) {
    final rawReceiptIds = json['receipt_ids'];
    final rawAttachments = json['attachment_urls'];
    final rawItems = json['line_items_snapshot'];
    final saleAt = DateTime.tryParse(json['sale_at']?.toString() ?? '');
    final requestedAt = DateTime.tryParse(
      json['requested_at']?.toString() ?? '',
    );
    if (saleAt == null || requestedAt == null) {
      throw const FormatException('RED_INVOICE_INTAKE_INVALID_DATE');
    }
    return RedInvoiceIntake(
      id: _requiredText(json['id'], 'RED_INVOICE_INTAKE_INVALID_ID'),
      orderId: _requiredText(
        json['order_id'],
        'RED_INVOICE_INTAKE_INVALID_ORDER',
      ),
      storeId: _requiredText(
        json['store_id'],
        'RED_INVOICE_INTAKE_INVALID_STORE',
      ),
      storeName: json['store_name']?.toString() ?? '',
      meInvoiceJobId: json['meinvoice_job_id']?.toString(),
      invoiceSeries: json['invoice_series']?.toString() ?? '',
      receiptIds: rawReceiptIds is List
          ? rawReceiptIds.map((value) => value.toString()).toList()
          : const <String>[],
      saleAt: saleAt,
      grossAmount: _toDouble(json['gross_amount']),
      paymentMethod: json['payment_method']?.toString() ?? '',
      source: json['source']?.toString() ?? 'cashier',
      status: json['status']?.toString() ?? 'awaiting_information',
      buyerTaxCode: json['buyer_tax_code']?.toString() ?? '',
      buyerUnitCode: json['buyer_unit_code']?.toString() ?? '',
      buyerLegalName: json['buyer_legal_name']?.toString() ?? '',
      buyerFullName: json['buyer_full_name']?.toString() ?? '',
      buyerAddress: json['buyer_address']?.toString() ?? '',
      buyerEmail: json['buyer_email']?.toString() ?? '',
      buyerEmailCc: json['buyer_email_cc']?.toString() ?? '',
      buyerPhone: json['buyer_phone']?.toString() ?? '',
      buyerId: json['buyer_id']?.toString() ?? '',
      sourceNote: json['source_note']?.toString() ?? '',
      attachmentUrls: rawAttachments is List
          ? rawAttachments.map((value) => value.toString()).toList()
          : const <String>[],
      requestedAt: requestedAt,
      exportBatchId: json['export_batch_id']?.toString(),
      lineItems: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) => RedInvoiceLineItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList()
          : const <RedInvoiceLineItem>[],
      meInvoiceStatus: json['meinvoice_status']?.toString(),
    );
  }

  final String id;
  final String orderId;
  final String storeId;
  final String storeName;
  final String? meInvoiceJobId;
  final String invoiceSeries;
  final List<String> receiptIds;
  final DateTime saleAt;
  final double grossAmount;
  final String paymentMethod;
  final String source;
  final String status;
  final String buyerTaxCode;
  final String buyerUnitCode;
  final String buyerLegalName;
  final String buyerFullName;
  final String buyerAddress;
  final String buyerEmail;
  final String buyerEmailCc;
  final String buyerPhone;
  final String buyerId;
  final String sourceNote;
  final List<String> attachmentUrls;
  final DateTime requestedAt;
  final String? exportBatchId;
  final List<RedInvoiceLineItem> lineItems;
  final String? meInvoiceStatus;

  DateTime get saleAtHcm => saleAt.toUtc().add(const Duration(hours: 7));

  bool get hasCompleteBuyerInformation =>
      buyerTaxCode.trim().isNotEmpty &&
      buyerLegalName.trim().isNotEmpty &&
      buyerAddress.trim().isNotEmpty &&
      buyerEmail.contains('@');

  double get totalAmountWithoutVat =>
      lineItems.fold<double>(0, (total, item) => total + item.amountWithoutVat);

  double get totalVatAmount =>
      lineItems.fold<double>(0, (total, item) => total + item.vatAmount);
}

class RedInvoiceDailyExport {
  const RedInvoiceDailyExport({
    required this.businessDate,
    required this.status,
    required this.finalizedAt,
    required this.requests,
  });

  factory RedInvoiceDailyExport.fromJson(Map<String, dynamic> json) {
    final status = json['status']?.toString() ?? 'pending';
    final rawRequests = json['requests'];
    if (rawRequests is! List) {
      throw const FormatException('RED_INVOICE_EXPORT_INVALID_REQUESTS');
    }
    return RedInvoiceDailyExport(
      businessDate: _requiredText(
        json['business_date'],
        'RED_INVOICE_EXPORT_INVALID_DATE',
      ),
      status: status,
      finalizedAt: DateTime.tryParse(json['finalized_at']?.toString() ?? ''),
      requests: rawRequests
          .whereType<Map>()
          .map(
            (row) => RedInvoiceIntake.fromJson(Map<String, dynamic>.from(row)),
          )
          .toList(),
    );
  }

  final String businessDate;
  final String status;
  final DateTime? finalizedAt;
  final List<RedInvoiceIntake> requests;
}

List<RedInvoiceIntake> parseRedInvoiceIntakeList(Map<String, dynamic> payload) {
  final raw = payload['requests'];
  if (raw is! List) {
    throw const FormatException('RED_INVOICE_INTAKE_INVALID_RESPONSE');
  }
  return raw
      .whereType<Map>()
      .map((row) => RedInvoiceIntake.fromJson(Map<String, dynamic>.from(row)))
      .toList();
}

List<int> buildRedInvoiceWorkbook({
  required RedInvoiceDailyExport export,
  required String exportBatchId,
}) {
  if (export.status != 'finalized') {
    throw const FormatException('RED_INVOICE_EXPORT_NOT_READY');
  }
  if (export.requests.isEmpty) {
    throw const FormatException('RED_INVOICE_EXPORT_EMPTY');
  }
  if (export.requests.any((request) => request.lineItems.isEmpty)) {
    throw const FormatException('RED_INVOICE_EXPORT_LINE_ITEMS_REQUIRED');
  }

  final workbook = Excel.createExcel();
  workbook.rename('Sheet1', 'Red Invoices');
  workbook.setDefaultSheet('Red Invoices');
  final invoices = workbook['Red Invoices'];
  invoices.appendRow([
    TextCellValue('ExportBatchID'),
    TextCellValue('RefID'),
    TextCellValue('IntakeID'),
    TextCellValue('OrderID'),
    TextCellValue('ReceiptIDs'),
    TextCellValue('Store'),
    TextCellValue('InvSeries'),
    TextCellValue('InvoiceName'),
    TextCellValue('InvDate'),
    TextCellValue('CurrencyCode'),
    TextCellValue('ExchangeRate'),
    TextCellValue('PaymentMethodName'),
    TextCellValue('BuyerCode'),
    TextCellValue('BuyerTaxCode'),
    TextCellValue('BuyerLegalName'),
    TextCellValue('BuyerFullName'),
    TextCellValue('BuyerAddress'),
    TextCellValue('BuyerEmail'),
    TextCellValue('BuyerEmailCC'),
    TextCellValue('BuyerPhoneNumber'),
    TextCellValue('AccountObjectIdentificationNumber'),
    TextCellValue('TotalAmountWithoutVAT'),
    TextCellValue('TotalVATAmount'),
    TextCellValue('TotalAmount'),
  ]);

  for (final request in export.requests) {
    invoices.appendRow([
      TextCellValue(exportBatchId),
      TextCellValue(request.meInvoiceJobId ?? request.id),
      TextCellValue(request.id),
      TextCellValue(request.orderId),
      TextCellValue(request.receiptIds.join(';')),
      TextCellValue(request.storeName),
      TextCellValue(request.invoiceSeries),
      TextCellValue('Hóa đơn GTGT khởi tạo từ máy tính tiền'),
      TextCellValue(_hcmDateTime(request.saleAtHcm)),
      TextCellValue('VND'),
      DoubleCellValue(1),
      TextCellValue(request.paymentMethod),
      TextCellValue(request.buyerUnitCode),
      TextCellValue(request.buyerTaxCode),
      TextCellValue(request.buyerLegalName),
      TextCellValue(request.buyerFullName),
      TextCellValue(request.buyerAddress),
      TextCellValue(request.buyerEmail),
      TextCellValue(request.buyerEmailCc),
      TextCellValue(request.buyerPhone),
      TextCellValue(request.buyerId),
      DoubleCellValue(request.totalAmountWithoutVat),
      DoubleCellValue(request.totalVatAmount),
      DoubleCellValue(request.grossAmount),
    ]);
  }
  for (var index = 0; index < 24; index++) {
    invoices.setColumnWidth(index, index >= 14 && index <= 19 ? 28 : 20);
  }

  final details = workbook['Invoice Details'];
  details.appendRow([
    TextCellValue('RefID'),
    TextCellValue('OrderID'),
    TextCellValue('ItemType'),
    TextCellValue('LineNumber'),
    TextCellValue('SortOrder'),
    TextCellValue('ItemCode'),
    TextCellValue('ItemName'),
    TextCellValue('UnitName'),
    TextCellValue('Quantity'),
    TextCellValue('UnitPrice'),
    TextCellValue('DiscountRate'),
    TextCellValue('DiscountAmount'),
    TextCellValue('Amount'),
    TextCellValue('AmountWithoutVAT'),
    TextCellValue('VATRateName'),
    TextCellValue('VATAmount'),
    TextCellValue('AmountAfterTax'),
  ]);
  for (final request in export.requests) {
    for (var index = 0; index < request.lineItems.length; index++) {
      final item = request.lineItems[index];
      details.appendRow([
        TextCellValue(request.meInvoiceJobId ?? request.id),
        TextCellValue(request.orderId),
        IntCellValue(1),
        IntCellValue(index + 1),
        IntCellValue(index + 1),
        TextCellValue(item.id),
        TextCellValue(item.name),
        TextCellValue('item'),
        DoubleCellValue(item.quantity),
        DoubleCellValue(item.unitPrice),
        DoubleCellValue(0),
        DoubleCellValue(0),
        DoubleCellValue(item.amountWithoutVat),
        DoubleCellValue(item.amountWithoutVat),
        TextCellValue(_vatRateName(item.vatRate)),
        DoubleCellValue(item.vatAmount),
        DoubleCellValue(item.amountAfterTax),
      ]);
    }
  }
  for (var index = 0; index < 17; index++) {
    details.setColumnWidth(index, index == 6 ? 32 : 20);
  }

  final audit = workbook['Intake Audit'];
  audit.appendRow([
    TextCellValue('IntakeID'),
    TextCellValue('OrderID'),
    TextCellValue('Source'),
    TextCellValue('Status'),
    TextCellValue('SourceNote'),
    TextCellValue('AttachmentCount'),
    TextCellValue('AttachmentURLs'),
    TextCellValue('RequestedAt'),
    TextCellValue('MeInvoiceStatus'),
  ]);
  for (final request in export.requests) {
    audit.appendRow([
      TextCellValue(request.id),
      TextCellValue(request.orderId),
      TextCellValue(request.source),
      TextCellValue(request.status),
      TextCellValue(request.sourceNote),
      IntCellValue(request.attachmentUrls.length),
      TextCellValue(request.attachmentUrls.join('\n')),
      TextCellValue(
        _hcmDateTime(request.requestedAt.toUtc().add(const Duration(hours: 7))),
      ),
      TextCellValue(request.meInvoiceStatus ?? ''),
    ]);
  }

  final summary = workbook['Summary'];
  summary.appendRow([
    TextCellValue('Business Date'),
    TextCellValue(export.businessDate),
  ]);
  summary.appendRow([
    TextCellValue('Export Batch ID'),
    TextCellValue(exportBatchId),
  ]);
  summary.appendRow([
    TextCellValue('Red Invoice Count'),
    IntCellValue(export.requests.length),
  ]);
  summary.appendRow([
    TextCellValue('Total Amount'),
    DoubleCellValue(
      export.requests.fold<double>(
        0,
        (total, request) => total + request.grossAmount,
      ),
    ),
  ]);
  summary.appendRow([
    TextCellValue('Matching Rule'),
    TextCellValue('Match ReceiptIDs to the original restaurant sales export'),
  ]);

  return workbook.encode() ?? <int>[];
}

String _requiredText(dynamic value, String error) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) throw FormatException(error);
  return text;
}

double _toDouble(dynamic value) {
  return switch (value) {
    num number => number.toDouble(),
    String text => double.tryParse(text.trim()) ?? 0,
    _ => 0,
  };
}

String _hcmDateTime(DateTime value) {
  return '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')} '
      '${value.hour.toString().padLeft(2, '0')}:'
      '${value.minute.toString().padLeft(2, '0')}:'
      '${value.second.toString().padLeft(2, '0')}';
}

String _vatRateName(double rate) {
  if (!rate.isFinite || rate <= 0) return '0%';
  final rounded = (rate * 100).round() / 100;
  return '${rounded == rounded.roundToDouble() ? rounded.toInt() : rounded}%';
}
