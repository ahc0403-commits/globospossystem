import '../admin/einvoice_misa_workbook.dart';

bool _isBlockingRestaurantIssue(String issue) => issue.isNotEmpty;

class RestaurantSalesLineItem {
  const RestaurantSalesLineItem({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    required this.supplyAmount,
    required this.vatRate,
    required this.vatAmount,
    this.itemType = '',
    this.orderItemId = '',
    this.menuItemId = '',
    this.invoiceName = '',
    this.unitName = '',
    this.approval = const {},
    this.invoiceUnitPrice,
    this.discountAmount,
    this.sourceOrderItemId = '',
  });

  final String name;
  final double quantity;
  final double unitPrice;
  final double supplyAmount;
  final double vatRate;
  final double vatAmount;
  final String itemType;
  final String orderItemId;
  final String menuItemId;
  final String invoiceName;
  final String unitName;
  final Map<String, dynamic> approval;
  final double? invoiceUnitPrice, discountAmount;
  final String sourceOrderItemId;

  double get grossAmount => supplyAmount + vatAmount;
  double get misaUnitPrice => invoiceUnitPrice ?? supplyAmount / quantity;
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
    required this.buyerEmail,
    required this.buyerPhone,
    required this.lineItems,
    required this.issues,
    this.storeCode = '',
    this.storeNameOrigin = 'current_registry',
    this.receiptNumber = '',
    this.paymentMethods = const [],
    this.snapshotVersion = 1,
    this.sourceHash = '',
    this.externallyReported = false,
  });

  final String storeId;
  final String storeName;
  final String storeCode;
  final String storeNameOrigin;
  final String receiptId;
  final String receiptNumber;
  final List<String> paymentMethods;
  final int snapshotVersion;
  final String sourceHash;
  final bool externallyReported;
  String get displayReceiptNumber =>
      receiptNumber.isEmpty ? receiptId : receiptNumber;
  final String receiptSource;
  final String salesChannel;
  final double grossSales;
  final DateTime soldAt;
  final String paymentMethod;
  final bool isRedInvoice;
  final String buyerTaxCode;
  final String buyerLegalName;
  final String buyerAddress;
  final String buyerEmail;
  final String buyerPhone;
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
    required this.taxEntityId,
    required this.sellerTaxCode,
    required this.sellerLegalName,
    required this.isSampleEntity,
    required this.storeCount,
    required this.receiptCount,
    required this.grossSales,
    required this.finalizedAt,
    required this.receipts,
  });

  final String businessDate;
  final String taxEntityId;
  final String sellerTaxCode;
  final String sellerLegalName;
  final bool isSampleEntity;
  final int storeCount;
  final int receiptCount;
  final double grossSales;
  final DateTime? finalizedAt;
  final List<RestaurantSalesReceipt> receipts;

  int get redInvoiceCount =>
      receipts.where((receipt) => receipt.isRedInvoice).length;
  int get generalReceiptCount => receiptCount - redInvoiceCount;
  int get lineCount =>
      receipts.fold(0, (total, receipt) => total + receipt.lineItems.length);
  int get sourceItemCount => receipts.fold(
    0,
    (n, r) =>
        n +
        r.lineItems
            .map(
              (l) => l.sourceOrderItemId.isEmpty
                  ? l.orderItemId.split(':').first
                  : l.sourceOrderItemId,
            )
            .toSet()
            .length,
  );
  int get roundedLineGross => receipts.fold(
    0,
    (total, receipt) =>
        total +
        receipt.lineItems.fold<int>(
          0,
          (sum, line) =>
              sum + line.supplyAmount.round() + line.vatAmount.round(),
        ),
  );
  double get supplyAmount =>
      receipts.fold(0, (total, receipt) => total + receipt.supplyAmount);
  double get vatAmount =>
      receipts.fold(0, (total, receipt) => total + receipt.vatAmount);
  int get blockingIssueCount => receipts.fold(
    0,
    (total, receipt) =>
        total + receipt.issues.where(_isBlockingRestaurantIssue).length,
  );
  bool get isReadyForDownload =>
      !isSampleEntity && receiptCount > 0 && blockingIssueCount == 0;
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
  if (status != 'ready' && status != 'finalized') {
    throw const FormatException('RESTAURANT_EXPORT_INVALID_STATUS');
  }

  final taxEntityId = _requiredText(
    payload['tax_entity_id'],
    'RESTAURANT_EXPORT_INVALID_TAX_ENTITY_ID',
  );
  final sellerTaxCode = _requiredText(
    payload['seller_tax_code'],
    'RESTAURANT_EXPORT_INVALID_SELLER_TAX_CODE',
  );
  final sellerLegalName = _requiredText(
    payload['seller_legal_name'],
    'RESTAURANT_EXPORT_INVALID_SELLER_LEGAL_NAME',
  );
  final isSampleEntity = payload['is_sample_entity'] == true;

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
  if (status == 'finalized' && finalizedAt == null) {
    throw const FormatException('RESTAURANT_EXPORT_INVALID_FINALIZED_AT');
  }
  if (status == 'ready' &&
      DateTime.tryParse(payload['report_ready_at']?.toString() ?? '') == null) {
    throw const FormatException('RESTAURANT_EXPORT_INVALID_REPORT_READY_AT');
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
        if (row['tax_entity_id'] != null &&
            row['tax_entity_id'].toString() != taxEntityId) {
          throw FormatException(
            'RESTAURANT_EXPORT_TAX_ENTITY_MISMATCH:$receiptId',
          );
        }
        if (row['seller_tax_code'] != null &&
            row['seller_tax_code'].toString() != sellerTaxCode) {
          throw FormatException(
            'RESTAURANT_EXPORT_SELLER_TAX_CODE_MISMATCH:$receiptId',
          );
        }
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
        final buyerEmail = row['buyer_email']?.toString().trim() ?? '';
        final buyerPhone = row['buyer_phone']?.toString().trim() ?? '';
        final rawLines = row['line_items'];
        final lines = rawLines is List
            ? rawLines
                  .whereType<Map>()
                  .map((rawLine) {
                    final line = Map<String, dynamic>.from(rawLine);
                    return RestaurantSalesLineItem(
                      approval: {
                        for (final k in [
                          'invoice_profile_id',
                          'invoice_approval_type',
                          'invoice_mapping_version',
                          'invoice_effective_from',
                          'invoice_effective_to',
                          'invoice_store_id',
                          'invoice_source_reference',
                        ])
                          k: line[k],
                      },
                      sourceOrderItemId:
                          line['source_order_item_id']?.toString() ?? '',
                      invoiceUnitPrice: salesExportNumber(
                        line['misa_unit_price'],
                      ),
                      discountAmount: salesExportNumber(
                        line['misa_discount_amount'],
                      ),
                      itemType: line['item_type']?.toString() ?? '',
                      orderItemId: line['order_item_id']?.toString() ?? '',
                      menuItemId: line['menu_item_id']?.toString() ?? '',
                      invoiceName: line['invoice_name_vi']?.toString() ?? '',
                      unitName: line['misa_unit_name']?.toString() ?? '',
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
          if (row['externally_reported'] == true) 'EXTERNALLY_REPORTED',
          if (lines.isEmpty) 'MISSING_LINE_ITEMS',
          if (lines.any(
            (line) =>
                line.invoiceName.isEmpty ||
                line.unitName.isEmpty ||
                line.orderItemId.isEmpty,
          ))
            'MISSING_APPROVED_INVOICE_METADATA',
          if (lines.any(
            (line) => !misaSourceVatMatches(
              line.supplyAmount,
              line.vatRate,
              line.vatAmount,
            ),
          ))
            'VAT_AMOUNT_MISMATCH',
          if (!misaSourceVatSummaryMatches(
            lines.map(
              (line) => (
                supply: line.supplyAmount,
                rate: line.vatRate,
                vat: line.vatAmount,
              ),
            ),
          ))
            'VAT_SUMMARY_MISMATCH',
          if (lines.any(
            (line) => line.itemType == 'wet_tissue_charge' && line.vatRate != 8,
          ))
            'WET_TISSUE_VAT_MISMATCH',
          if (isRedInvoice && buyerTaxCode.isEmpty) 'MISSING_BUYER_TAX_CODE',
          if (isRedInvoice && buyerLegalName.isEmpty)
            'MISSING_BUYER_LEGAL_NAME',
          if (isRedInvoice && buyerAddress.isEmpty) 'MISSING_BUYER_ADDRESS',
          if (isRedInvoice && buyerEmail.isEmpty) 'MISSING_BUYER_EMAIL',
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
          storeCode: row['store_code']?.toString() ?? '',
          storeNameOrigin:
              row['store_name_origin']?.toString() ?? 'current_registry',
          receiptId: receiptId,
          receiptNumber: row['receipt_number']?.toString() ?? '',
          paymentMethods: (row['payment_methods'] as List? ?? const [])
              .map((v) => v.toString())
              .toList(),
          snapshotVersion: (row['snapshot_version'] as num?)?.toInt() ?? 1,
          sourceHash: row['source_hash']?.toString() ?? '',
          externallyReported: row['externally_reported'] == true,
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
          buyerEmail: buyerEmail,
          buyerPhone: buyerPhone,
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
    taxEntityId: taxEntityId,
    sellerTaxCode: sellerTaxCode,
    sellerLegalName: sellerLegalName,
    isSampleEntity: isSampleEntity,
    storeCount: storeCount,
    receiptCount: receiptCount,
    grossSales: grossSales,
    finalizedAt: finalizedAt,
    receipts: List.unmodifiable(receipts),
  );
}

List<RestaurantSalesExport> createRestaurantSalesExportsByTaxEntity(
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
  if (status != 'ready' && status != 'finalized') {
    throw const FormatException('RESTAURANT_EXPORT_INVALID_STATUS');
  }

  final rawEntities = payload['entities'];
  if (rawEntities is! List) {
    throw const FormatException('RESTAURANT_EXPORT_INVALID_ENTITIES');
  }
  final finalizedAt = payload['finalized_at']?.toString();
  final reportReadyAt = payload['report_ready_at']?.toString();
  if (status == 'finalized' && DateTime.tryParse(finalizedAt ?? '') == null) {
    throw const FormatException('RESTAURANT_EXPORT_INVALID_FINALIZED_AT');
  }
  if (status == 'ready' && DateTime.tryParse(reportReadyAt ?? '') == null) {
    throw const FormatException('RESTAURANT_EXPORT_INVALID_REPORT_READY_AT');
  }
  final exports = rawEntities
      .map((raw) {
        if (raw is! Map) {
          throw const FormatException('RESTAURANT_EXPORT_INVALID_ENTITY');
        }
        final entity = Map<String, dynamic>.from(raw);
        entity['business_date'] = businessDate;
        entity['status'] = status;
        entity['finalized_at'] = finalizedAt;
        entity['report_ready_at'] = reportReadyAt;
        return createRestaurantSalesExport(entity);
      })
      .toList(growable: false);

  final expectedEntityCount = payload['entity_count'];
  if (expectedEntityCount != null &&
      _nonNegativeInt(
            expectedEntityCount,
            'RESTAURANT_EXPORT_INVALID_ENTITY_COUNT',
          ) !=
          exports.length) {
    throw const FormatException('RESTAURANT_EXPORT_ENTITY_COUNT_MISMATCH');
  }
  if (exports.map((export) => export.taxEntityId).toSet().length !=
      exports.length) {
    throw const FormatException('RESTAURANT_EXPORT_DUPLICATE_TAX_ENTITY');
  }
  final receiptIds = exports
      .expand((export) => export.receipts)
      .map((receipt) => receipt.receiptId)
      .toList(growable: false);
  if (receiptIds.toSet().length != receiptIds.length) {
    throw const FormatException('RESTAURANT_EXPORT_CROSS_ENTITY_RECEIPT');
  }

  return List.unmodifiable(exports);
}

List<int> buildRestaurantSalesWorkbook(RestaurantSalesExport export) {
  if (!export.isReadyForDownload) {
    throw restaurantExportValidationException(export);
  }

  return buildMisaPendingInvoiceWorkbook(
    export.receipts
        .map(
          (receipt) => {
            ...buildRestaurantMisaJob(receipt),
            'tax_entity_id': export.taxEntityId,
          },
        )
        .toList(),
  );
}

/// One invoice per receipt; every sold line keeps its original tax amounts.
Map<String, dynamic> buildRestaurantMisaJob(RestaurantSalesReceipt receipt) {
  final lines = <Map<String, dynamic>>[];
  for (final line in receipt.lineItems) {
    lines.add({
      ...line.approval,
      'source_order_item_id': line.sourceOrderItemId.isEmpty
          ? line.orderItemId.split(':').first
          : line.sourceOrderItemId,
      'order_item_id': line.orderItemId,
      'menu_item_id': line.menuItemId,
      'display_name': line.invoiceName,
      'invoice_name_vi': line.invoiceName,
      'misa_unit_name': line.unitName,
      'item_type': line.itemType,
      'quantity': line.quantity,
      'unit_price': line.unitPrice,
      'misa_unit_price': line.invoiceUnitPrice,
      'misa_discount_amount': line.discountAmount,
      'total_amount_ex_tax': line.supplyAmount,
      'vat_rate': line.vatRate,
      'vat_amount': line.vatAmount,
      'paying_amount_inc_tax': line.grossAmount,
    });
  }
  final buyerName = receipt.isRedInvoice ? receipt.buyerLegalName : '';
  return {
    'source_system': 'restaurant_pos',
    'store_id': receipt.storeId,
    'store_code': receipt.storeCode,
    'store_name': receipt.storeName,
    'store_name_origin': receipt.storeNameOrigin,
    'externally_reported': receipt.externallyReported,
    'receipt_id': receipt.receiptId,
    'receipt_number': receipt.displayReceiptNumber,
    'snapshot_version': receipt.snapshotVersion,
    'gross_sales': receipt.grossSales,
    if (receipt.sourceHash.isNotEmpty) 'source_hash': receipt.sourceHash,
    'payment_methods': receipt.paymentMethods,
    'created_at': receipt.soldAt.toIso8601String(),
    'payment_method_snapshot': receipt.paymentMethod,
    'misa_buyer_person_name': receipt.isRedInvoice
        ? ''
        : 'Bán cho người tiêu dùng',
    'buyer_snapshot': {
      'unit_name': buyerName,
      'customer_name': buyerName,
      'tax_code': receipt.isRedInvoice ? receipt.buyerTaxCode : '',
      'address': receipt.isRedInvoice ? receipt.buyerAddress : '',
      'email': receipt.buyerEmail,
      'phone': receipt.buyerPhone,
    },
    'line_items_snapshot': lines,
  };
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

SalesExportValidationException restaurantExportValidationException(
  RestaurantSalesExport export,
) {
  final issues = validateSalesExportJobs(
    export.receipts
        .map(
          (r) => {
            ...buildRestaurantMisaJob(r),
            'tax_entity_id': export.taxEntityId,
          },
        )
        .toList(),
  );
  for (final r in export.receipts) {
    for (final code in r.issues) {
      issues.add(
        SalesExportIssue(
          receiptId: r.receiptId,
          receiptNumber: r.displayReceiptNumber,
          source: 'restaurant_pos',
          itemId: '',
          itemName: '',
          field: 'receipt',
          code: code,
          soldAt: r.soldAt.toIso8601String(),
        ),
      );
    }
  }
  if (issues.isEmpty) {
    issues.add(
      const SalesExportIssue(
        receiptId: '',
        receiptNumber: '',
        source: '',
        itemId: '',
        itemName: '',
        field: 'scope',
        code: 'RESTAURANT_EXPORT_BLOCKING_ISSUES',
        soldAt: '',
      ),
    );
  }
  return SalesExportValidationException(issues);
}
