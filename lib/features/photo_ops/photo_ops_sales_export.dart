import 'package:excel/excel.dart';

class PhotoOpsReceiptRow {
  const PhotoOpsReceiptRow({
    required this.storeId,
    required this.storeName,
    required this.soldAt,
    required this.saleTimeText,
    required this.deviceName,
    required this.deviceId,
    required this.amount,
    required this.rawType,
    required this.paymentMethod,
    required this.receiptId,
  });

  final String storeId;
  final String storeName;
  final DateTime soldAt;
  final String saleTimeText;
  final String deviceName;
  final String deviceId;
  final int amount;
  final String rawType;
  final String paymentMethod;
  final String receiptId;

  DateTime get soldAtHcm => soldAt.toUtc().add(const Duration(hours: 7));

  String get hourBucket {
    final hour = soldAtHcm.hour.toString().padLeft(2, '0');
    return '$hour:00-$hour:59';
  }
}

class PhotoOpsHourlyTotal {
  const PhotoOpsHourlyTotal({required this.receiptCount, required this.amount});

  final int receiptCount;
  final int amount;
}

class PhotoOpsSalesExport {
  const PhotoOpsSalesExport({
    required this.saleDate,
    required this.taxEntityId,
    required this.storeCount,
    required this.receipts,
    required this.hourlyTotals,
  });

  final String saleDate;
  final String taxEntityId;
  final int storeCount;
  final List<PhotoOpsReceiptRow> receipts;
  final Map<String, PhotoOpsHourlyTotal> hourlyTotals;

  int get receiptCount => receipts.length;
  int get totalAmount => receipts.fold(0, (sum, row) => sum + row.amount);
}

void validatePhotoOpsSalesExportReady({
  required List<Map<String, dynamic>> stores,
  required List<Map<String, dynamic>> completedRuns,
}) {
  final requiredStoreIds = stores
      .map(
        (store) => _requiredText(store['id'], 'PHOTO_EXPORT_INVALID_STORE_ID'),
      )
      .toSet();
  final completedStoreIds = completedRuns
      .map(
        (run) => _requiredText(
          run['store_id'],
          'PHOTO_EXPORT_INVALID_PULL_RUN_STORE',
        ),
      )
      .toSet();
  final missingCount = requiredStoreIds.difference(completedStoreIds).length;
  if (missingCount != 0) {
    throw FormatException('PHOTO_EXPORT_NOT_READY:$missingCount');
  }
}

PhotoOpsSalesExport createPhotoOpsSalesExport({
  required String saleDate,
  required List<Map<String, dynamic>> stores,
  required List<Map<String, dynamic>> rawSales,
}) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(saleDate)) {
    throw const FormatException('PHOTO_EXPORT_INVALID_SALE_DATE');
  }
  if (stores.isEmpty) {
    throw const FormatException('PHOTO_EXPORT_NO_ACCESSIBLE_STORES');
  }

  final storeNames = <String, String>{};
  final taxEntityIds = <String>{};
  for (final store in stores) {
    final storeId = _requiredText(store['id'], 'PHOTO_EXPORT_INVALID_STORE_ID');
    final taxEntityId = _requiredText(
      store['tax_entity_id'],
      'PHOTO_EXPORT_INVALID_TAX_ENTITY',
    );
    storeNames[storeId] = _requiredText(
      store['name'],
      'PHOTO_EXPORT_INVALID_STORE_NAME',
    );
    taxEntityIds.add(taxEntityId);
  }

  if (taxEntityIds.length != 1) {
    throw const FormatException('PHOTO_EXPORT_MULTIPLE_TAX_ENTITIES');
  }

  final receipts =
      rawSales.map((raw) {
        final rawId = _requiredText(raw['id'], 'PHOTO_EXPORT_INVALID_RAW_ID');
        final storeId = _requiredText(
          raw['store_id'],
          'PHOTO_EXPORT_INVALID_RAW_STORE',
        );
        final storeName = storeNames[storeId];
        if (storeName == null) {
          throw FormatException('PHOTO_EXPORT_UNKNOWN_STORE:$rawId');
        }

        final soldAt = DateTime.tryParse(raw['sold_at']?.toString() ?? '');
        if (soldAt == null) {
          throw FormatException('PHOTO_EXPORT_INVALID_SOLD_AT:$rawId');
        }
        final hcm = soldAt.toUtc().add(const Duration(hours: 7));
        final rowDate =
            '${hcm.year.toString().padLeft(4, '0')}-'
            '${hcm.month.toString().padLeft(2, '0')}-'
            '${hcm.day.toString().padLeft(2, '0')}';
        if (rowDate != saleDate) {
          throw FormatException('PHOTO_EXPORT_SALE_DATE_MISMATCH:$rawId');
        }

        final amount = _positiveInt(raw['amount']);
        if (amount == null) {
          throw FormatException('PHOTO_EXPORT_INVALID_AMOUNT:$rawId');
        }

        return PhotoOpsReceiptRow(
          storeId: storeId,
          storeName: storeName,
          soldAt: soldAt,
          saleTimeText: raw['sale_time_text']?.toString().trim() ?? '',
          deviceName: raw['device_name']?.toString().trim() ?? '',
          deviceId: raw['device_id']?.toString().trim() ?? '',
          amount: amount,
          rawType: raw['raw_type']?.toString().trim() ?? '',
          paymentMethod: raw['payment_method']?.toString().trim() ?? '',
          receiptId: _requiredText(
            raw['source_hash'],
            'PHOTO_EXPORT_INVALID_RECEIPT_ID:$rawId',
          ),
        );
      }).toList()..sort((a, b) {
        final timeOrder = a.soldAt.compareTo(b.soldAt);
        return timeOrder != 0 ? timeOrder : a.receiptId.compareTo(b.receiptId);
      });

  final hourlyCounts = <String, int>{};
  final hourlyAmounts = <String, int>{};
  for (final receipt in receipts) {
    hourlyCounts.update(
      receipt.hourBucket,
      (value) => value + 1,
      ifAbsent: () => 1,
    );
    hourlyAmounts.update(
      receipt.hourBucket,
      (value) => value + receipt.amount,
      ifAbsent: () => receipt.amount,
    );
  }
  final hourlyTotals = <String, PhotoOpsHourlyTotal>{};
  for (final hour in hourlyCounts.keys.toList()..sort()) {
    hourlyTotals[hour] = PhotoOpsHourlyTotal(
      receiptCount: hourlyCounts[hour]!,
      amount: hourlyAmounts[hour]!,
    );
  }

  return PhotoOpsSalesExport(
    saleDate: saleDate,
    taxEntityId: taxEntityIds.single,
    storeCount: storeNames.length,
    receipts: List.unmodifiable(receipts),
    hourlyTotals: Map.unmodifiable(hourlyTotals),
  );
}

List<int> buildPhotoOpsSalesWorkbook(PhotoOpsSalesExport export) {
  final workbook = Excel.createExcel();
  workbook.rename('Sheet1', 'Sales');
  workbook.setDefaultSheet('Sales');

  final sales = workbook['Sales'];
  sales.appendRow([
    TextCellValue('Store'),
    TextCellValue('Device Name'),
    TextCellValue('Device ID'),
    TextCellValue('Time'),
    TextCellValue('Amount'),
    TextCellValue('Type'),
    TextCellValue('Receipt ID'),
    TextCellValue('Hour'),
    TextCellValue('Payment Method'),
    TextCellValue('Sold At (HCM)'),
  ]);
  for (final receipt in export.receipts) {
    final hcm = receipt.soldAtHcm;
    final time = receipt.saleTimeText.isNotEmpty
        ? receipt.saleTimeText
        : _hcmTime(hcm);
    sales.appendRow([
      TextCellValue(receipt.storeName),
      TextCellValue(receipt.deviceName),
      TextCellValue(receipt.deviceId),
      TextCellValue(time),
      IntCellValue(receipt.amount),
      TextCellValue(receipt.rawType),
      TextCellValue(receipt.receiptId),
      TextCellValue(receipt.hourBucket),
      TextCellValue(receipt.paymentMethod),
      TextCellValue('${export.saleDate} ${_hcmTime(hcm)}'),
    ]);
  }
  for (var index = 0; index < 10; index++) {
    sales.setColumnWidth(index, index == 6 ? 36 : 18);
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
      IntCellValue(entry.value.amount),
    ]);
  }
  hourly.appendRow([
    TextCellValue('Total'),
    IntCellValue(export.receiptCount),
    IntCellValue(export.totalAmount),
  ]);

  final summary = workbook['Summary'];
  summary.appendRow([
    TextCellValue('Sale Date'),
    TextCellValue(export.saleDate),
  ]);
  summary.appendRow([
    TextCellValue('Legal Entity ID'),
    TextCellValue(export.taxEntityId),
  ]);
  summary.appendRow([
    TextCellValue('Store Count'),
    IntCellValue(export.storeCount),
  ]);
  summary.appendRow([
    TextCellValue('Receipt Count'),
    IntCellValue(export.receiptCount),
  ]);
  summary.appendRow([
    TextCellValue('Total Amount'),
    IntCellValue(export.totalAmount),
  ]);

  return workbook.encode() ?? <int>[];
}

String _requiredText(dynamic value, String error) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) throw FormatException(error);
  return text;
}

int? _positiveInt(dynamic value) {
  final parsed = switch (value) {
    int number => number,
    num number => number.toInt(),
    String text => int.tryParse(text.trim()),
    _ => null,
  };
  return parsed != null && parsed > 0 ? parsed : null;
}

String _hcmTime(DateTime value) =>
    '${value.hour.toString().padLeft(2, '0')}:'
    '${value.minute.toString().padLeft(2, '0')}:'
    '${value.second.toString().padLeft(2, '0')}';
