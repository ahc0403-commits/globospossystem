import '../../core/payments/collection_bank.dart';

class DailySalesSummary {
  DailySalesSummary.fromJson(this.businessDate, Map<String, dynamic> row)
    : taxEntityId = row['tax_entity_id'] as String,
      sellerTaxCode = row['seller_tax_code'] as String,
      sellerLegalName = row['seller_legal_name'] as String,
      restaurantReceiptCount = _amount(row['restaurant_receipt_count']).toInt(),
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
  int get receiptCount => restaurantReceiptCount + photoReceiptCount;
  double get gross => restaurantGross + photoGross;
  double? get nextDeposit => photoComplete ? photoGross + restaurantCash : null;
  bool get depositConfirmed =>
      photoComplete &&
      closingComplete &&
      ((closingDeposit != null &&
              (closingDeposit! - restaurantCash).abs() <= 1) ||
          (closingDeposit == null &&
              restaurantReceiptCount == 0 &&
              restaurantCash == 0));
  String get depositDate => DateTime.parse(
    businessDate,
  ).add(const Duration(days: 1)).toIso8601String().substring(0, 10);
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
