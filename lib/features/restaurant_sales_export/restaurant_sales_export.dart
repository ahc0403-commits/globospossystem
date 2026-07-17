import 'package:excel/excel.dart';

class RestaurantSalesReceipt {
  const RestaurantSalesReceipt({
    required this.storeId,
    required this.storeName,
    required this.receiptId,
    required this.receiptSource,
    required this.salesChannel,
    required this.grossSales,
    required this.soldAt,
  });

  final String storeId;
  final String storeName;
  final String receiptId;
  final String receiptSource;
  final String salesChannel;
  final double grossSales;
  final DateTime soldAt;

  DateTime get soldAtHcm => soldAt.toUtc().add(const Duration(hours: 7));

  String get hourBucket {
    final hour = soldAtHcm.hour.toString().padLeft(2, '0');
    return '$hour:00-$hour:59';
  }
}

class RestaurantSalesHourlyTotal {
  const RestaurantSalesHourlyTotal({
    required this.receiptCount,
    required this.grossSales,
  });

  final int receiptCount;
  final double grossSales;
}

class RestaurantSalesExport {
  const RestaurantSalesExport({
    required this.businessDate,
    required this.storeCount,
    required this.receiptCount,
    required this.grossSales,
    required this.finalizedAt,
    required this.receipts,
    required this.hourlyTotals,
  });

  final String businessDate;
  final int storeCount;
  final int receiptCount;
  final double grossSales;
  final DateTime finalizedAt;
  final List<RestaurantSalesReceipt> receipts;
  final Map<String, RestaurantSalesHourlyTotal> hourlyTotals;
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
        final soldAt = DateTime.tryParse(row['sold_at']?.toString() ?? '');
        if (soldAt == null) {
          throw FormatException('RESTAURANT_EXPORT_INVALID_SOLD_AT:$receiptId');
        }
        if (restaurantHcmBusinessDate(soldAt) != businessDate) {
          throw FormatException(
            'RESTAURANT_EXPORT_BUSINESS_DATE_MISMATCH:$receiptId',
          );
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
          receiptSource: _requiredText(
            row['receipt_source'],
            'RESTAURANT_EXPORT_INVALID_RECEIPT_SOURCE:$receiptId',
          ),
          salesChannel: row['sales_channel']?.toString().trim() ?? '',
          grossSales: _nonNegativeDouble(
            row['gross_sales'],
            'RESTAURANT_EXPORT_INVALID_RECEIPT_AMOUNT:$receiptId',
          ),
          soldAt: soldAt,
        );
      }).toList()..sort((a, b) {
        final timeOrder = a.soldAt.compareTo(b.soldAt);
        return timeOrder != 0 ? timeOrder : a.receiptId.compareTo(b.receiptId);
      });

  if (receipts.length != receiptCount) {
    throw const FormatException('RESTAURANT_EXPORT_RECEIPT_COUNT_MISMATCH');
  }
  final receiptGrossSales = receipts.fold<double>(
    0,
    (sum, receipt) => sum + receipt.grossSales,
  );
  if ((receiptGrossSales - grossSales).abs() > 0.005) {
    throw const FormatException('RESTAURANT_EXPORT_GROSS_SALES_MISMATCH');
  }

  final hourlyCounts = <String, int>{};
  final hourlySales = <String, double>{};
  for (final receipt in receipts) {
    hourlyCounts.update(
      receipt.hourBucket,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    hourlySales.update(
      receipt.hourBucket,
      (value) => value + receipt.grossSales,
      ifAbsent: () => receipt.grossSales,
    );
  }
  final hourlyTotals = <String, RestaurantSalesHourlyTotal>{};
  for (final hour in hourlyCounts.keys.toList()..sort()) {
    hourlyTotals[hour] = RestaurantSalesHourlyTotal(
      receiptCount: hourlyCounts[hour]!,
      grossSales: hourlySales[hour]!,
    );
  }

  return RestaurantSalesExport(
    businessDate: businessDate,
    storeCount: storeCount,
    receiptCount: receiptCount,
    grossSales: grossSales,
    finalizedAt: finalizedAt,
    receipts: List.unmodifiable(receipts),
    hourlyTotals: Map.unmodifiable(hourlyTotals),
  );
}

List<int> buildRestaurantSalesWorkbook(RestaurantSalesExport export) {
  final workbook = Excel.createExcel();
  workbook.rename('Sheet1', 'Sales');
  workbook.setDefaultSheet('Sales');

  final sales = workbook['Sales'];
  sales.appendRow([
    TextCellValue('Store'),
    TextCellValue('Time'),
    TextCellValue('Amount'),
    TextCellValue('Source'),
    TextCellValue('Sales Channel'),
    TextCellValue('Receipt ID'),
    TextCellValue('Hour'),
    TextCellValue('Sold At (HCM)'),
  ]);
  for (final receipt in export.receipts) {
    final hcm = receipt.soldAtHcm;
    sales.appendRow([
      TextCellValue(receipt.storeName),
      TextCellValue(_hcmTime(hcm)),
      DoubleCellValue(receipt.grossSales),
      TextCellValue(receipt.receiptSource),
      TextCellValue(receipt.salesChannel),
      TextCellValue(receipt.receiptId),
      TextCellValue(receipt.hourBucket),
      TextCellValue('${export.businessDate} ${_hcmTime(hcm)}'),
    ]);
  }
  for (var index = 0; index < 8; index++) {
    sales.setColumnWidth(index, index == 5 ? 36 : 20);
  }

  final hourly = workbook['Hourly Summary'];
  hourly.appendRow([
    TextCellValue('Hour'),
    TextCellValue('Receipt Count'),
    TextCellValue('Amount'),
  ]);
  for (final entry in export.hourlyTotals.entries) {
    hourly.appendRow([
      TextCellValue(entry.key),
      IntCellValue(entry.value.receiptCount),
      DoubleCellValue(entry.value.grossSales),
    ]);
  }
  hourly.appendRow([
    TextCellValue('Total'),
    IntCellValue(export.receiptCount),
    DoubleCellValue(export.grossSales),
  ]);

  final summary = workbook['Summary'];
  summary.appendRow([
    TextCellValue('Business Date'),
    TextCellValue(export.businessDate),
  ]);
  summary.appendRow([TextCellValue('Status'), TextCellValue('finalized')]);
  summary.appendRow([
    TextCellValue('Store Count'),
    IntCellValue(export.storeCount),
  ]);
  summary.appendRow([
    TextCellValue('Receipt Count'),
    IntCellValue(export.receiptCount),
  ]);
  summary.appendRow([
    TextCellValue('Gross Sales'),
    DoubleCellValue(export.grossSales),
  ]);
  summary.appendRow([
    TextCellValue('Finalized At'),
    TextCellValue(export.finalizedAt.toIso8601String()),
  ]);

  return workbook.encode() ?? <int>[];
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

String _hcmTime(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}:'
    '${value.second.toString().padLeft(2, '0')}';
