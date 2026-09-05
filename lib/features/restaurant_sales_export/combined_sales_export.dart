import '../admin/einvoice_misa_workbook.dart';
import '../photo_sales_import/photo_sales_registered_export.dart';
import 'restaurant_sales_export.dart';

class CombinedSalesExport {
  const CombinedSalesExport({
    required this.taxEntityId,
    required this.sellerTaxCode,
    required this.sellerLegalName,
    required this.restaurant,
    required this.photo,
  });

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
  bool get isReadyForDownload => receiptCount > 0 && blockingIssueCount == 0;
}

List<CombinedSalesExport> combineSalesExportsByTaxEntity({
  required List<RestaurantSalesExport> restaurantExports,
  required List<PhotoSalesRegisteredExport> photoExports,
}) {
  final combined = <String, CombinedSalesExport>{};
  for (final restaurant in restaurantExports) {
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

List<int> buildCombinedSalesWorkbook(CombinedSalesExport export) {
  if (!export.isReadyForDownload) {
    throw const FormatException('COMBINED_SALES_EXPORT_BLOCKING_ISSUES');
  }
  final jobs = <Map<String, dynamic>>[
    if (export.restaurant case final restaurant?)
      ...restaurant.receipts.map(buildRestaurantMisaJob),
    if (export.photo case final photo?)
      ...buildPhotoSalesRegisteredMisaJobs(photo),
  ];
  return buildMisaPendingInvoiceWorkbook(jobs);
}
