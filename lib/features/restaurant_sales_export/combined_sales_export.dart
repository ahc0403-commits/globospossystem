import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';
import '../admin/einvoice_misa_workbook.dart';
import '../admin/misa_description_normalization.dart';
import '../photo_sales_import/photo_sales_registered_export.dart';
import 'restaurant_sales_export.dart';

class CombinedSalesExport {
  const CombinedSalesExport({
    required this.taxEntityId,
    required this.sellerTaxCode,
    required this.sellerLegalName,
    required this.restaurant,
    required this.photo,
    this.sourceRevision,
    this.mappingRevision,
  });

  final String? sourceRevision;
  final int? mappingRevision;
  final String taxEntityId;
  final String sellerTaxCode;
  final String sellerLegalName;
  final RestaurantSalesExport? restaurant;
  final PhotoSalesRegisteredExport? photo;

  String get businessDate =>
      restaurant?.businessDate ?? photo?.businessDate ?? '';
  bool get isSampleEntity => restaurant?.isSampleEntity ?? false;
  int get restaurantReceiptCount => restaurant?.receiptCount ?? 0;
  int get photoReceiptCount => photo?.receiptCount ?? 0;
  int get receiptCount => restaurantReceiptCount + photoReceiptCount;
  int get lineCount => (restaurant?.lineCount ?? 0) + photoReceiptCount;
  int get sourceItemCount =>
      (restaurant?.sourceItemCount ?? 0) + photoReceiptCount;
  int get roundedLineGross =>
      (restaurant?.roundedLineGross ?? 0) +
      (photo?.receipts.fold<int>(0, (n, r) {
            final split = splitMisaGrossAmount(r.amount.toDouble(), 8);
            return n + split.supplyAmount.round() + split.vatAmount.round();
          }) ??
          0);
  double get roundingDifference => grossSales - roundedLineGross;
  int get generalReceiptCount => restaurant?.generalReceiptCount ?? 0;
  int get redInvoiceCount => restaurant?.redInvoiceCount ?? 0;
  double get restaurantGrossSales => restaurant?.grossSales ?? 0;
  int get photoGrossSales => photo?.grossSales ?? 0;
  double get grossSales => restaurantGrossSales + photoGrossSales;
  double get supplyAmount =>
      (restaurant?.supplyAmount ?? 0) + (photo?.supplyAmount ?? 0);
  double get vatAmount =>
      (restaurant?.vatAmount ?? 0) + (photo?.vatAmount ?? 0);
  int get blockingIssueCount => restaurant?.blockingIssueCount ?? 0;
  bool get isReadyForDownload =>
      !isSampleEntity && receiptCount > 0 && blockingIssueCount == 0;
}

List<CombinedSalesExport> combineSalesExportsByTaxEntity({
  required List<RestaurantSalesExport> restaurantExports,
  required List<PhotoSalesRegisteredExport> photoExports,
}) {
  final sampleEntityIds = restaurantExports
      .where((export) => export.isSampleEntity)
      .map((export) => export.taxEntityId)
      .toSet();
  final combined = <String, CombinedSalesExport>{};
  for (final restaurant in restaurantExports) {
    if (restaurant.isSampleEntity) continue;
    if (combined.containsKey(restaurant.taxEntityId)) {
      throw const FormatException('COMBINED_SALES_DUPLICATE_RESTAURANT_ENTITY');
    }
    combined[restaurant.taxEntityId] = CombinedSalesExport(
      taxEntityId: restaurant.taxEntityId,
      sellerTaxCode: restaurant.sellerTaxCode,
      sellerLegalName: restaurant.sellerLegalName,
      restaurant: restaurant,
      photo: null,
    );
  }
  for (final photo in photoExports) {
    if (sampleEntityIds.contains(photo.taxEntityId)) continue;
    final current = combined[photo.taxEntityId];
    if (current?.photo != null) {
      throw const FormatException('COMBINED_SALES_DUPLICATE_PHOTO_ENTITY');
    }
    if (current != null &&
        (current.sellerTaxCode != photo.sellerTaxCode ||
            current.sellerLegalName != photo.sellerLegalName ||
            current.businessDate != photo.businessDate)) {
      throw const FormatException('COMBINED_SALES_ENTITY_MISMATCH');
    }
    combined[photo.taxEntityId] = CombinedSalesExport(
      taxEntityId: photo.taxEntityId,
      sellerTaxCode: photo.sellerTaxCode,
      sellerLegalName: photo.sellerLegalName,
      restaurant: current?.restaurant,
      photo: photo,
    );
  }
  return combined.values.toList(growable: false)..sort((a, b) {
    final sampleOrder = a.isSampleEntity == b.isSampleEntity
        ? 0
        : (a.isSampleEntity ? 1 : -1);
    return sampleOrder != 0
        ? sampleOrder
        : a.sellerTaxCode.compareTo(b.sellerTaxCode);
  });
}

List<int> buildCombinedSalesWorkbook(
  CombinedSalesExport export, {
  String? generationId,
  List<Map<String, dynamic>>? descriptionNormalizations,
}) {
  if (!export.isReadyForDownload) {
    if (export.restaurant != null) {
      throw restaurantExportValidationException(export.restaurant!);
    }
    throw const FormatException('COMBINED_SALES_EXPORT_BLOCKING_ISSUES');
  }
  final jobs = <Map<String, dynamic>>[
    if (export.restaurant case final restaurant?)
      ...restaurant.receipts.map(
        (receipt) => {
          ...buildRestaurantMisaJob(receipt),
          'tax_entity_id': export.taxEntityId,
        },
      ),
    if (export.photo case final photo?)
      ...buildPhotoSalesRegisteredMisaJobs(photo),
  ];
  return buildMisaPendingInvoiceWorkbook(
    jobs,
    generationId: generationId,
    descriptionNormalizations: descriptionNormalizations,
  );
}

class SalesExportArtifact {
  const SalesExportArtifact(this.bytes, this.manifest);
  final List<int> bytes;
  final Map<String, dynamic> manifest;
  String get manifestJson =>
      const JsonEncoder.withIndent('  ').convert(manifest);
}

SalesExportArtifact buildCombinedSalesArtifact(
  CombinedSalesExport export, {
  String? batchId,
}) {
  final id = batchId ?? const Uuid().v4();
  final descriptionNormalizations = <Map<String, dynamic>>[];
  final bytes = buildCombinedSalesWorkbook(
    export,
    generationId: id,
    descriptionNormalizations: descriptionNormalizations,
  );
  final counts = <String, int>{};
  final gross = <String, double>{};
  void add(String store, num amount) {
    counts.update(store, (n) => n + 1, ifAbsent: () => 1);
    gross.update(store, (n) => n + amount, ifAbsent: () => amount.toDouble());
  }

  for (final receipt
      in export.restaurant?.receipts ?? <RestaurantSalesReceipt>[]) {
    add(receipt.storeId, receipt.grossSales);
  }
  for (final receipt
      in export.photo?.receipts ?? <PhotoSalesRegisteredReceipt>[]) {
    add(receipt.storeId, receipt.amount);
  }
  final stores = counts.keys.toList()..sort();
  return SalesExportArtifact(bytes, {
    'format_version': 'pos-sales-xlsx-v4',
    'ledger_version': 3,
    if (export.restaurant != null) ...{
      'description_normalization_policy': misaDescriptionPolicy,
      'description_normalizations': descriptionNormalizations,
    },
    'generation_id': id,
    if (batchId != null) 'reporting_batch_id': batchId,
    'source_revision': export.sourceRevision,
    'mapping_revision': export.mappingRevision,
    'business_date': export.businessDate,
    'tax_entity_id': export.taxEntityId,
    'store_ids': stores,
    'store_totals': [
      for (final store in stores)
        {
          'store_id': store,
          'receipt_count': counts[store],
          'gross': gross[store]!.toStringAsFixed(2),
        },
    ],
    'file_sha256': sha256.convert(bytes).toString(),
    'file_size': bytes.length,
    'receipt_count': export.receiptCount,
    'source_item_count': export.sourceItemCount,
    'export_line_count': export.lineCount,
    'source_gross': export.grossSales.toStringAsFixed(2),
    'rounded_line_gross': export.roundedLineGross,
    'rounding_difference': export.roundingDifference.toStringAsFixed(2),
  });
}
