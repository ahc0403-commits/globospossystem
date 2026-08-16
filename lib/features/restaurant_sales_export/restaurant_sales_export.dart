import 'package:excel/excel.dart';

class RestaurantSalesLineItem {
  const RestaurantSalesLineItem({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    required this.supplyAmount,
    required this.vatRate,
    required this.vatAmount,
  });

  final String name;
  final double quantity;
  final double unitPrice;
  final double supplyAmount;
  final double vatRate;
  final double vatAmount;

  double get grossAmount => supplyAmount + vatAmount;
  double get misaUnitPrice => supplyAmount / quantity;
}

class RestaurantSalesReceipt {
  const RestaurantSalesReceipt({
    required this.storeId,
    required this.storeName,
    required this.receiptId,
    required this.receiptSource,
    required this.salesChannel,
    required this.grossSales,
    required this.soldAt,
    required this.paymentMethod,
    required this.isRedInvoice,
    required this.buyerTaxCode,
    required this.buyerLegalName,
    required this.buyerAddress,
    required this.lineItems,
    required this.issues,
  });

  final String storeId;
  final String storeName;
  final String receiptId;
  final String receiptSource;
  final String salesChannel;
  final double grossSales;
  final DateTime soldAt;
  final String paymentMethod;
  final bool isRedInvoice;
  final String buyerTaxCode;
  final String buyerLegalName;
  final String buyerAddress;
  final List<RestaurantSalesLineItem> lineItems;
  final List<String> issues;

  DateTime get soldAtHcm => soldAt.toUtc().add(const Duration(hours: 7));
  double get supplyAmount =>
      lineItems.fold(0, (total, item) => total + item.supplyAmount);
  double get vatAmount =>
      lineItems.fold(0, (total, item) => total + item.vatAmount);
}

class RestaurantSalesExport {
  const RestaurantSalesExport({
    required this.businessDate,
    required this.storeCount,
    required this.receiptCount,
    required this.grossSales,
    required this.finalizedAt,
    required this.receipts,
  });

  final String businessDate;
  final int storeCount;
  final int receiptCount;
  final double grossSales;
  final DateTime finalizedAt;
  final List<RestaurantSalesReceipt> receipts;

  int get redInvoiceCount =>
      receipts.where((receipt) => receipt.isRedInvoice).length;
  int get generalReceiptCount => receiptCount - redInvoiceCount;
  int get lineCount =>
      receipts.fold(0, (total, receipt) => total + receipt.lineItems.length);
  double get supplyAmount =>
      receipts.fold(0, (total, receipt) => total + receipt.supplyAmount);
  double get vatAmount =>
      receipts.fold(0, (total, receipt) => total + receipt.vatAmount);
  int get blockingIssueCount =>
      receipts.fold(0, (total, receipt) => total + receipt.issues.length);
  bool get isReadyForDownload => receiptCount > 0 && blockingIssueCount == 0;
}

String restaurantHcmBusinessDate(DateTime value) {
  final hcm = value.toUtc().add(const Duration(hours: 7));
  return '${hcm.year.toString().padLeft(4, '0')}-'
      '${hcm.month.toString().padLeft(2, '0')}-'
      '${hcm.day.toString().padLeft(2, '0')}';
}

RestaurantSalesExport createRestaurantSalesExport(
  Map<String, dynamic> payload,
) {
  final businessDate = _requiredText(
    payload['business_date'],
    'RESTAURANT_EXPORT_INVALID_BUSINESS_DATE',
  );
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(businessDate)) {
    throw const FormatException('RESTAURANT_EXPORT_INVALID_BUSINESS_DATE');
  }

  final status = _requiredText(
    payload['status'],
    'RESTAURANT_EXPORT_INVALID_STATUS',
  );
  if (status == 'pending') {
    throw const FormatException('RESTAURANT_EXPORT_NOT_READY');
  }
  if (status == 'data_integrity_failed') {
    throw const FormatException('RESTAURANT_EXPORT_DATA_INTEGRITY_FAILED');
  }
  if (status != 'finalized') {
    throw const FormatException('RESTAURANT_EXPORT_INVALID_STATUS');
  }

  final storeCount = _nonNegativeInt(
    payload['store_count'],
    'RESTAURANT_EXPORT_INVALID_STORE_COUNT',
  );
  final receiptCount = _nonNegativeInt(
    payload['receipt_count'],
    'RESTAURANT_EXPORT_INVALID_RECEIPT_COUNT',
  );
  final grossSales = _nonNegativeDouble(
    payload['gross_sales'],
    'RESTAURANT_EXPORT_INVALID_GROSS_SALES',
  );
  final finalizedAt = DateTime.tryParse(
    payload['finalized_at']?.toString() ?? '',
  );
  if (finalizedAt == null) {
    throw const FormatException('RESTAURANT_EXPORT_INVALID_FINALIZED_AT');
  }

  final rawReceipts = payload['receipts'];
  if (rawReceipts is! List) {
    throw const FormatException('RESTAURANT_EXPORT_INVALID_RECEIPTS');
  }

  final receipts =
      rawReceipts.map((raw) {
        if (raw is! Map) {
          throw const FormatException('RESTAURANT_EXPORT_INVALID_RECEIPT');
        }
        final row = Map<String, dynamic>.from(raw);
        final receiptId = _requiredText(
          row['receipt_id'],
          'RESTAURANT_EXPORT_INVALID_RECEIPT_ID',
        );
        final sourceSystem =
            row['source_system']?.toString() ?? 'restaurant_pos';
        if (sourceSystem == 'photo_objet_moers') {
          throw FormatException('RESTAURANT_EXPORT_PHOTO_SOURCE:$receiptId');
        }
        if (sourceSystem != 'restaurant_pos') {
          throw FormatException('RESTAURANT_EXPORT_INVALID_SOURCE:$receiptId');
        }
        final receiptSource =
            row['receipt_source']?.toString() ?? 'pos_payment';
        if (receiptSource != 'pos_payment') {
          throw FormatException(
            'RESTAURANT_EXPORT_INVALID_RECEIPT_SOURCE:$receiptId',
          );
        }
        final soldAt = DateTime.tryParse(row['sold_at']?.toString() ?? '');
        if (soldAt == null) {
          throw FormatException('RESTAURANT_EXPORT_INVALID_SOLD_AT:$receiptId');
        }
        if (restaurantHcmBusinessDate(soldAt) != businessDate) {
          throw FormatException(
            'RESTAURANT_EXPORT_BUSINESS_DATE_MISMATCH:$receiptId',
          );
        }

        final isRedInvoice = row['is_red_invoice'] == true;
        final redInvoiceStatus =
            row['red_invoice_status']?.toString() ??
            (isRedInvoice ? 'ready' : '');
        final buyerTaxCode = row['buyer_tax_code']?.toString().trim() ?? '';
        final buyerLegalName = row['buyer_legal_name']?.toString().trim() ?? '';
        final buyerAddress = row['buyer_address']?.toString().trim() ?? '';
        final rawLines = row['line_items'];
        final lines = rawLines is List
            ? rawLines
                  .whereType<Map>()
                  .map((rawLine) {
                    final line = Map<String, dynamic>.from(rawLine);
                    return RestaurantSalesLineItem(
                      name: _requiredText(
                        line['display_name'] ?? line['name'],
                        'RESTAURANT_EXPORT_INVALID_LINE_NAME:$receiptId',
                      ),
                      quantity: _positiveDouble(
                        line['quantity'],
                        'RESTAURANT_EXPORT_INVALID_LINE_QUANTITY:$receiptId',
                      ),
                      unitPrice: _nonNegativeDouble(
                        line['unit_price'],
                        'RESTAURANT_EXPORT_INVALID_UNIT_PRICE:$receiptId',
                      ),
                      supplyAmount: _nonNegativeDouble(
                        line['total_amount_ex_tax'] ?? line['supply_amount'],
                        'RESTAURANT_EXPORT_INVALID_SUPPLY_AMOUNT:$receiptId',
                      ),
                      vatRate: _nonNegativeDouble(
                        line['vat_rate'],
                        'RESTAURANT_EXPORT_INVALID_VAT_RATE:$receiptId',
                      ),
                      vatAmount: _nonNegativeDouble(
                        line['vat_amount'],
                        'RESTAURANT_EXPORT_INVALID_VAT_AMOUNT:$receiptId',
                      ),
                    );
                  })
                  .toList(growable: false)
            : const <RestaurantSalesLineItem>[];

        final receiptGross = _nonNegativeDouble(
          row['gross_sales'],
          'RESTAURANT_EXPORT_INVALID_RECEIPT_AMOUNT:$receiptId',
        );
        final issues = <String>[
          if (lines.isEmpty) 'MISSING_LINE_ITEMS',
          if (isRedInvoice && buyerTaxCode.isEmpty) 'MISSING_BUYER_TAX_CODE',
          if (isRedInvoice && buyerLegalName.isEmpty)
            'MISSING_BUYER_LEGAL_NAME',
          if (isRedInvoice && buyerAddress.isEmpty) 'MISSING_BUYER_ADDRESS',
          if (isRedInvoice &&
              !const {
                'ready',
                'exported',
                'completed',
              }.contains(redInvoiceStatus))
            'RED_INVOICE_NOT_READY',
        ];
        final lineGross = lines.fold<double>(
          0,
          (total, line) => total + line.grossAmount,
        );
        if (lines.isNotEmpty && (lineGross - receiptGross).abs() > 1) {
          issues.add('AMOUNT_MISMATCH');
        }

        return RestaurantSalesReceipt(
          storeId: _requiredText(
            row['store_id'],
            'RESTAURANT_EXPORT_INVALID_STORE_ID:$receiptId',
          ),
          storeName: _requiredText(
            row['store_name'],
            'RESTAURANT_EXPORT_INVALID_STORE_NAME:$receiptId',
          ),
          receiptId: receiptId,
          receiptSource: receiptSource,
          salesChannel: row['sales_channel']?.toString() ?? '',
          grossSales: receiptGross,
          soldAt: soldAt,
          paymentMethod: _requiredText(
            row['payment_method'],
            'RESTAURANT_EXPORT_INVALID_PAYMENT_METHOD:$receiptId',
          ),
          isRedInvoice: isRedInvoice,
          buyerTaxCode: buyerTaxCode,
          buyerLegalName: buyerLegalName,
          buyerAddress: buyerAddress,
          lineItems: List.unmodifiable(lines),
          issues: List.unmodifiable(issues),
        );
      }).toList()..sort((a, b) {
        final timeOrder = a.soldAt.compareTo(b.soldAt);
        return timeOrder != 0 ? timeOrder : a.receiptId.compareTo(b.receiptId);
      });

  if (receipts.length != receiptCount) {
    throw const FormatException('RESTAURANT_EXPORT_RECEIPT_COUNT_MISMATCH');
  }
  if (receipts.map((receipt) => receipt.receiptId).toSet().length !=
      receiptCount) {
    throw const FormatException('RESTAURANT_EXPORT_DUPLICATE_RECEIPT');
  }
  final receiptGrossSales = receipts.fold<double>(
    0,
    (sum, receipt) => sum + receipt.grossSales,
  );
  if ((receiptGrossSales - grossSales).abs() > 1) {
    throw const FormatException('RESTAURANT_EXPORT_GROSS_SALES_MISMATCH');
  }

  return RestaurantSalesExport(
    businessDate: businessDate,
    storeCount: storeCount,
    receiptCount: receiptCount,
    grossSales: grossSales,
    finalizedAt: finalizedAt,
    receipts: List.unmodifiable(receipts),
  );
}

List<int> buildRestaurantSalesWorkbook(RestaurantSalesExport export) {
  if (!export.isReadyForDownload) {
    throw const FormatException('RESTAURANT_EXPORT_BLOCKING_ISSUES');
  }

  final workbook = Excel.createExcel();
  workbook.rename('Sheet1', 'Hóa đơn GTGT');
  workbook.setDefaultSheet('Hóa đơn GTGT');
  final sheet = workbook['Hóa đơn GTGT'];

  for (final instruction in _misaInstructions) {
    sheet.appendRow([TextCellValue(instruction)]);
  }
  sheet.appendRow([TextCellValue('')]);
  sheet.appendRow(_misaHeaders.map(TextCellValue.new).toList());

  for (
    var receiptIndex = 0;
    receiptIndex < export.receipts.length;
    receiptIndex += 1
  ) {
    final receipt = export.receipts[receiptIndex];
    final buyerName = receipt.isRedInvoice
        ? receipt.buyerLegalName
        : 'Bán cho người tiêu dùng';
    for (final line in receipt.lineItems) {
      sheet.appendRow([
        IntCellValue(receiptIndex + 1),
        TextCellValue(_misaDate(receipt.soldAtHcm)),
        TextCellValue(buyerName),
        TextCellValue(receipt.isRedInvoice ? receipt.buyerTaxCode : ''),
        TextCellValue(receipt.isRedInvoice ? receipt.buyerAddress : ''),
        TextCellValue(receipt.isRedInvoice ? '' : 'Bán cho người tiêu dùng'),
        TextCellValue(''),
        TextCellValue(''),
        TextCellValue(''),
        TextCellValue(_misaPaymentCode(receipt.paymentMethod)),
        TextCellValue(line.name),
        TextCellValue('Phần'),
        DoubleCellValue(line.quantity),
        DoubleCellValue(line.misaUnitPrice),
        DoubleCellValue(line.supplyAmount),
        DoubleCellValue(line.vatRate),
        DoubleCellValue(line.vatAmount),
      ]);
    }
  }

  for (var index = 0; index < _misaHeaders.length; index += 1) {
    sheet.setColumnWidth(index, switch (index) {
      2 || 4 || 5 || 10 => 28,
      _ => 18,
    });
  }
  return workbook.encode() ?? <int>[];
}

const _misaInstructions = <String>[
  'File mẫu danh sách hóa đơn để nhập vào phần mềm ',
  'Hướng dẫn:',
  '- Điền dữ liệu hóa đơn cần lập trên phần mềm vào các cột tương ứng trên file này',
  '- Các cột có dấu (*) là những cột bắt buộc',
  '- Nếu muốn nhập thêm thông tin khác, người dùng có thể tự thêm cột trên file này (VD: Mã khách hàng, Mã hàng, Tỷ lệ chiết khấu,...)',
  '- Các dòng dữ liệu phía dưới chỉ là ví dụ minh họa',
];

const _misaHeaders = <String>[
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

String _misaDate(DateTime value) =>
    '${value.day.toString().padLeft(2, '0')}/'
    '${value.month.toString().padLeft(2, '0')}/'
    '${value.year.toString().padLeft(4, '0')}';

String _misaPaymentCode(String value) {
  final normalized = value.trim().toLowerCase();
  if (normalized == 'tm' ||
      normalized.contains('cash') ||
      normalized.contains('tiền mặt') ||
      normalized.contains('tien mat')) {
    return 'TM';
  }
  if (normalized == 'ck' ||
      normalized.contains('card') ||
      normalized.contains('transfer') ||
      normalized.contains('thẻ') ||
      normalized.contains('chuyển khoản')) {
    return 'CK';
  }
  return value.trim();
}

String _requiredText(dynamic value, String error) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) throw FormatException(error);
  return text;
}

int _nonNegativeInt(dynamic value, String error) {
  final parsed = switch (value) {
    int number => number,
    num number => number.toInt(),
    String text => int.tryParse(text.trim()),
    _ => null,
  };
  if (parsed == null || parsed < 0) throw FormatException(error);
  return parsed;
}

double _nonNegativeDouble(dynamic value, String error) {
  final parsed = switch (value) {
    num number => number.toDouble(),
    String text => double.tryParse(text.trim()),
    _ => null,
  };
  if (parsed == null || !parsed.isFinite || parsed < 0) {
    throw FormatException(error);
  }
  return parsed;
}

double _positiveDouble(dynamic value, String error) {
  final parsed = _nonNegativeDouble(value, error);
  if (parsed <= 0) throw FormatException(error);
  return parsed;
}
