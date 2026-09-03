class PhotoSalesRegisteredReceipt {
  const PhotoSalesRegisteredReceipt({
    required this.sourceHash,
    required this.storeId,
    required this.storeName,
    required this.deviceName,
    required this.soldAt,
    required this.amount,
  });

  final String sourceHash;
  final String storeId;
  final String storeName;
  final String deviceName;
  final DateTime soldAt;
  final int amount;

  int get supplyAmount => (amount / 1.08).round();
  int get vatAmount => amount - supplyAmount;
}

class PhotoSalesRegisteredExport {
  const PhotoSalesRegisteredExport({
    required this.businessDate,
    required this.taxEntityId,
    required this.sellerTaxCode,
    required this.sellerLegalName,
    required this.storeCount,
    required this.receiptCount,
    required this.grossSales,
    required this.receipts,
  });

  final String businessDate;
  final String taxEntityId;
  final String sellerTaxCode;
  final String sellerLegalName;
  final int storeCount;
  final int receiptCount;
  final int grossSales;
  final List<PhotoSalesRegisteredReceipt> receipts;

  int get supplyAmount =>
      receipts.fold(0, (total, receipt) => total + receipt.supplyAmount);
  int get vatAmount =>
      receipts.fold(0, (total, receipt) => total + receipt.vatAmount);
}

List<PhotoSalesRegisteredExport> createPhotoSalesRegisteredExports(
  Map<String, dynamic> payload,
) {
  final businessDate = _requiredText(
    payload['business_date'],
    'PHOTO_SALES_EXPORT_INVALID_BUSINESS_DATE',
  );
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(businessDate)) {
    throw const FormatException('PHOTO_SALES_EXPORT_INVALID_BUSINESS_DATE');
  }
  final rawEntities = payload['entities'];
  if (rawEntities is! List) {
    throw const FormatException('PHOTO_SALES_EXPORT_INVALID_ENTITIES');
  }

  final exports = rawEntities
      .map((rawEntity) {
        if (rawEntity is! Map) {
          throw const FormatException('PHOTO_SALES_EXPORT_INVALID_ENTITY');
        }
        final entity = Map<String, dynamic>.from(rawEntity);
        final taxEntityId = _requiredText(
          entity['tax_entity_id'],
          'PHOTO_SALES_EXPORT_INVALID_TAX_ENTITY_ID',
        );
        final sellerTaxCode = _requiredText(
          entity['seller_tax_code'],
          'PHOTO_SALES_EXPORT_INVALID_SELLER_TAX_CODE',
        );
        final sellerLegalName = _requiredText(
          entity['seller_legal_name'],
          'PHOTO_SALES_EXPORT_INVALID_SELLER_LEGAL_NAME',
        );
        final storeCount = _nonNegativeInt(
          entity['store_count'],
          'PHOTO_SALES_EXPORT_INVALID_STORE_COUNT',
        );
        final receiptCount = _nonNegativeInt(
          entity['receipt_count'],
          'PHOTO_SALES_EXPORT_INVALID_RECEIPT_COUNT',
        );
        final grossSales = _nonNegativeInt(
          entity['gross_sales'],
          'PHOTO_SALES_EXPORT_INVALID_GROSS_SALES',
        );
        final rawReceipts = entity['receipts'];
        if (rawReceipts is! List) {
          throw const FormatException('PHOTO_SALES_EXPORT_INVALID_RECEIPTS');
        }

        final receipts = rawReceipts
            .map((rawReceipt) {
              if (rawReceipt is! Map) {
                throw const FormatException(
                  'PHOTO_SALES_EXPORT_INVALID_RECEIPT',
                );
              }
              final receipt = Map<String, dynamic>.from(rawReceipt);
              final sourceHash = _requiredText(
                receipt['source_hash'],
                'PHOTO_SALES_EXPORT_INVALID_SOURCE_HASH',
              );
              final soldAt = DateTime.tryParse(
                receipt['sold_at']?.toString() ?? '',
              );
              if (soldAt == null || _hcmDate(soldAt) != businessDate) {
                throw FormatException(
                  'PHOTO_SALES_EXPORT_INVALID_SOLD_AT:$sourceHash',
                );
              }
              final amount = _nonNegativeInt(
                receipt['amount'],
                'PHOTO_SALES_EXPORT_INVALID_AMOUNT:$sourceHash',
              );
              if (amount == 0) {
                throw FormatException(
                  'PHOTO_SALES_EXPORT_ZERO_AMOUNT:$sourceHash',
                );
              }
              return PhotoSalesRegisteredReceipt(
                sourceHash: sourceHash,
                storeId: _requiredText(
                  receipt['store_id'],
                  'PHOTO_SALES_EXPORT_INVALID_STORE_ID:$sourceHash',
                ),
                storeName: _requiredText(
                  receipt['store_name'],
                  'PHOTO_SALES_EXPORT_INVALID_STORE_NAME:$sourceHash',
                ),
                deviceName: _requiredText(
                  receipt['device_name'],
                  'PHOTO_SALES_EXPORT_INVALID_DEVICE_NAME:$sourceHash',
                ),
                soldAt: soldAt,
                amount: amount,
              );
            })
            .toList(growable: false);

        if (receipts.length != receiptCount ||
            receipts.map((receipt) => receipt.sourceHash).toSet().length !=
                receiptCount) {
          throw const FormatException(
            'PHOTO_SALES_EXPORT_RECEIPT_COUNT_MISMATCH',
          );
        }
        if (receipts.map((receipt) => receipt.storeId).toSet().length !=
            storeCount) {
          throw const FormatException(
            'PHOTO_SALES_EXPORT_STORE_COUNT_MISMATCH',
          );
        }
        if (receipts.fold<int>(0, (sum, receipt) => sum + receipt.amount) !=
            grossSales) {
          throw const FormatException(
            'PHOTO_SALES_EXPORT_GROSS_SALES_MISMATCH',
          );
        }
        return PhotoSalesRegisteredExport(
          businessDate: businessDate,
          taxEntityId: taxEntityId,
          sellerTaxCode: sellerTaxCode,
          sellerLegalName: sellerLegalName,
          storeCount: storeCount,
          receiptCount: receiptCount,
          grossSales: grossSales,
          receipts: List.unmodifiable(receipts),
        );
      })
      .toList(growable: false);

  final expectedEntityCount = _nonNegativeInt(
    payload['entity_count'],
    'PHOTO_SALES_EXPORT_INVALID_ENTITY_COUNT',
  );
  if (exports.length != expectedEntityCount ||
      exports.map((export) => export.taxEntityId).toSet().length !=
          exports.length) {
    throw const FormatException('PHOTO_SALES_EXPORT_ENTITY_COUNT_MISMATCH');
  }
  final sourceHashes = exports
      .expand((export) => export.receipts)
      .map((receipt) => receipt.sourceHash)
      .toList(growable: false);
  if (sourceHashes.toSet().length != sourceHashes.length) {
    throw const FormatException('PHOTO_SALES_EXPORT_CROSS_ENTITY_RECEIPT');
  }
  return List.unmodifiable(exports);
}

List<Map<String, dynamic>> buildPhotoSalesRegisteredMisaJobs(
  PhotoSalesRegisteredExport export,
) => export.receipts
    .map(
      (receipt) => <String, dynamic>{
        'source_system': 'photo_objet_moers',
        'source_snapshot': {'sale_date': receipt.soldAt.toIso8601String()},
        'created_at': receipt.soldAt.toIso8601String(),
        'payment_method_snapshot': 'CASH',
        'buyer_snapshot': const <String, dynamic>{},
        'line_items_snapshot': [
          {
            'display_name': 'Dịch vụ chụp ảnh',
            'quantity': 1,
            'paying_amount_inc_tax': receipt.amount,
          },
        ],
      },
    )
    .toList(growable: false);

String _hcmDate(DateTime value) {
  final hcm = value.toUtc().add(const Duration(hours: 7));
  return '${hcm.year.toString().padLeft(4, '0')}-'
      '${hcm.month.toString().padLeft(2, '0')}-'
      '${hcm.day.toString().padLeft(2, '0')}';
}

String _requiredText(Object? value, String error) {
  final text = value?.toString().trim() ?? '';
  if (text.isEmpty) throw FormatException(error);
  return text;
}

int _nonNegativeInt(Object? value, String error) {
  final parsed = switch (value) {
    int number => number,
    num number when number == number.roundToDouble() => number.toInt(),
    String text => int.tryParse(text.trim()),
    _ => null,
  };
  if (parsed == null || parsed < 0) throw FormatException(error);
  return parsed;
}
