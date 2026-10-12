import '../../core/payments/collection_bank.dart';
import '../../core/payments/cash_deposit.dart';

class DailySalesSummary {
  DailySalesSummary.fromJson(
    this.businessDate,
    Map<String, dynamic> row, {
    this.asOf,
  }) : taxEntityId = row['tax_entity_id'] as String,
       sellerTaxCode = row['seller_tax_code'] as String,
       sellerLegalName = row['seller_legal_name'] as String,
       restaurantReceiptCount = _amount(
         row['restaurant_receipt_count'],
       ).toInt(),
       photoReceiptCount = _amount(row['photo_receipt_count']).toInt(),
       generalCount = _amount(row['general_count']).toInt(),
       redCount = _amount(row['red_count']).toInt(),
       restaurantGross = _amount(row['restaurant_gross']),
       photoGross = _amount(row['photo_gross']),
       supply = _amount(row['supply']),
       vat = _amount(row['vat']),
       restaurantCash = _amount(row['restaurant_cash']),
       restaurantBankTransfer = _amount(row['restaurant_bank_transfer']),
       photoComplete = row['photo_complete'] == true,
       closingComplete = row['closing_complete'] == true,
       closingDeposit = row['closing_deposit'] == null
           ? null
           : _amount(row['closing_deposit']),
       cashVariance = _amount(row['cash_variance']),
       cashRefunds = _amount(row['cash_refunds']),
       deliveryCashPaid = _amount(row['delivery_cash_paid']),
       deliveryCashRecovered = _amount(row['delivery_cash_recovered']),
       missingPhotoStores = _optionalCount(row['missing_photo_store_count']),
       bunsikStoreCount = _optionalCount(row['bunsik_store_count']),
       bunsikClosedStores = _optionalCount(row['bunsik_closed_store_count']),
       bunsikShortfallStores = _optionalCount(
         row['bunsik_shortfall_store_count'],
       ),
       bunsikVarianceStores = _optionalCount(
         row['bunsik_variance_store_count'],
       ),
       bunsikLateLedgerStores = _optionalCount(
         row['bunsik_late_ledger_store_count'],
       ),
       bunsikClosedDeposit = _optionalAmount(row['bunsik_closed_deposit']),
       bunsikExpectedDeposit = _optionalAmount(row['bunsik_expected_deposit']),
       bunsikCash = _optionalAmount(row['bunsik_cash']),
       bunsikVariance = _optionalAmount(row['bunsik_variance']),
       bunsikStores = List.unmodifiable(
         (row['bunsik_stores'] as List? ?? const []).map(
           (r) => DepositStore.fromJson(Map<String, dynamic>.from(r as Map)),
         ),
       ),
       sourceRevision = row['source_revision'] as String?,
       exportMetadataDeferred = row['export_metadata_deferred'] == true,
       mappingRevision = (row['mapping_revision'] as num?)?.toInt(),
       sourceItemCount = (row['source_item_count'] as num?)?.toInt(),
       exportLineCount = (row['export_line_count'] as num?)?.toInt(),
       externallyReported = row['externally_reported'] == true,
       bank = row['bank'] is Map
           ? CollectionBank.fromJson(
               Map<String, dynamic>.from(row['bank'] as Map),
             )
           : null;
  final String businessDate, taxEntityId, sellerTaxCode, sellerLegalName;
  final int restaurantReceiptCount, photoReceiptCount, generalCount, redCount;
  final double restaurantGross,
      photoGross,
      supply,
      vat,
      restaurantCash,
      restaurantBankTransfer;
  final bool photoComplete, closingComplete;
  final double? closingDeposit;
  final double cashVariance,
      cashRefunds,
      deliveryCashPaid,
      deliveryCashRecovered;
  final CollectionBank? bank;
  final int? mappingRevision, sourceItemCount, exportLineCount;
  final bool externallyReported;
  final String? sourceRevision;
  final bool exportMetadataDeferred;
  final DateTime? asOf;
  final List<DepositStore> bunsikStores;
  final int? missingPhotoStores,
      bunsikStoreCount,
      bunsikClosedStores,
      bunsikShortfallStores,
      bunsikVarianceStores,
      bunsikLateLedgerStores;
  final double? bunsikClosedDeposit,
      bunsikExpectedDeposit,
      bunsikCash,
      bunsikVariance;
  int get receiptCount => restaurantReceiptCount + photoReceiptCount;
  double get gross => restaurantGross + photoGross;
  double? get photoDeposit => photoComplete ? photoGross : null;
  int? get pendingBunsikStores =>
      bunsikStoreCount == null || bunsikClosedStores == null
      ? null
      : bunsikStoreCount! - bunsikClosedStores!;
  bool get cashDepositConfirmed =>
      pendingBunsikStores == 0 &&
      bunsikShortfallStores == 0 &&
      (bunsikStoreCount == 0 || bunsikClosedDeposit != null);
  double? get cashDeposit =>
      cashDepositConfirmed ? (bunsikClosedDeposit ?? 0) : null;
  bool get cashNeedsReview =>
      (bunsikVarianceStores ?? 0) > 0 ||
      (bunsikLateLedgerStores ?? 0) > 0 ||
      (bunsikShortfallStores ?? 0) > 0;
  double? get nextDeposit => photoDeposit == null || cashDeposit == null
      ? null
      : photoDeposit! + cashDeposit!;
  bool get depositConfirmed => photoDeposit != null && cashDepositConfirmed;
  String get depositDate => nextDepositDate(businessDate);
  static double? _optionalAmount(Object? value) =>
      value == null ? null : _amount(value);
  static int? _optionalCount(Object? value) {
    if (value == null) return null;
    final amount = _amount(value);
    if (amount < 0 || amount != amount.truncateToDouble()) {
      throw const FormatException('SALES_SUMMARY_INVALID_COUNT');
    }
    return amount.toInt();
  }

  static double _amount(Object? value) {
    final parsed = value is num
        ? value.toDouble()
        : double.tryParse(value?.toString() ?? '');
    if (parsed == null || !parsed.isFinite) {
      throw const FormatException('SALES_SUMMARY_INVALID_AMOUNT');
    }
    return parsed;
  }
}

class DepositStore {
  const DepositStore(this.id, this.name);
  final String id, name;
  factory DepositStore.fromJson(Map<String, dynamic> row) {
    if (row['store_id'] is! String ||
        (row['store_id'] as String).isEmpty ||
        row['store_name'] is! String) {
      throw const FormatException('SALES_SUMMARY_SCOPE_INVALID');
    }
    return DepositStore(row['store_id'] as String, row['store_name'] as String);
  }
}
