const String vatPricingModeExclusive = 'exclusive';
const String vatPricingModeInclusive = 'inclusive';

class PaymentQuoteLine {
  const PaymentQuoteLine({
    required this.unitPrice,
    required this.quantity,
    required this.status,
    required this.itemType,
    this.vatCategory,
    this.payingAmountIncTax,
  });

  final double unitPrice;
  final int quantity;
  final String status;
  final String itemType;
  final String? vatCategory;
  final double? payingAmountIncTax;
}

class PaymentQuoteResult {
  const PaymentQuoteResult({
    required this.menuSubtotal,
    required this.serviceChargeTotal,
    required this.discountTotal,
    required this.payableTotal,
  });

  final double menuSubtotal;
  final double serviceChargeTotal;
  final double discountTotal;
  final double payableTotal;
}

PaymentQuoteResult calculatePaymentQuote({
  required Iterable<PaymentQuoteLine> lines,
  required String vatPricingMode,
  required bool serviceChargeEnabled,
  required double serviceChargeRate,
  double discountTotal = 0,
}) {
  var menuSubtotal = 0.0;
  var foodPretaxSubtotal = 0.0;
  var alcoholPretaxSubtotal = 0.0;
  var existingServiceChargeTotal = 0.0;
  var hasExistingServiceCharge = false;

  for (final line in lines) {
    if (line.status.toLowerCase() == 'cancelled') {
      continue;
    }

    final itemType = line.itemType.toLowerCase();
    if (itemType != 'menu_item') {
      if (itemType == 'service_charge') {
        hasExistingServiceCharge = true;
        existingServiceChargeTotal +=
            line.payingAmountIncTax != null && line.payingAmountIncTax! > 0
            ? line.payingAmountIncTax!
            : line.unitPrice * line.quantity;
      }
      continue;
    }

    final lineGross = _roundMoney(line.unitPrice * line.quantity);
    final vatRate = line.vatCategory?.toLowerCase() == 'alcohol' ? 10.0 : 8.0;
    late final double pretax;
    late final double incTax;

    if (vatPricingMode.toLowerCase() == vatPricingModeInclusive) {
      incTax = lineGross;
      pretax = _roundMoney(lineGross / (1 + (vatRate / 100)));
    } else {
      pretax = lineGross;
      incTax = pretax + _roundMoney(pretax * vatRate / 100);
    }

    menuSubtotal += incTax;
    if (vatRate == 10.0) {
      alcoholPretaxSubtotal += pretax;
    } else {
      foodPretaxSubtotal += pretax;
    }
  }

  final serviceChargeTotal = hasExistingServiceCharge
      ? existingServiceChargeTotal
      : _calculateGeneratedServiceChargeTotal(
          enabled: serviceChargeEnabled,
          rate: serviceChargeRate,
          foodPretaxSubtotal: foodPretaxSubtotal,
          alcoholPretaxSubtotal: alcoholPretaxSubtotal,
        );

  final resolvedDiscount = _roundMoney(
    discountTotal.clamp(0, menuSubtotal).toDouble(),
  );

  return PaymentQuoteResult(
    menuSubtotal: _roundMoney(menuSubtotal),
    serviceChargeTotal: _roundMoney(serviceChargeTotal),
    discountTotal: resolvedDiscount,
    payableTotal: _roundMoney(
      menuSubtotal + serviceChargeTotal - resolvedDiscount,
    ),
  );
}

double _calculateGeneratedServiceChargeTotal({
  required bool enabled,
  required double rate,
  required double foodPretaxSubtotal,
  required double alcoholPretaxSubtotal,
}) {
  if (!enabled || rate <= 0) {
    return 0;
  }

  var total = 0.0;
  if (foodPretaxSubtotal > 0) {
    final pretax = _roundMoney(foodPretaxSubtotal * rate / 100);
    total += pretax + _roundMoney(pretax * 8 / 100);
  }
  if (alcoholPretaxSubtotal > 0) {
    final pretax = _roundMoney(alcoholPretaxSubtotal * rate / 100);
    total += pretax + _roundMoney(pretax * 10 / 100);
  }
  return _roundMoney(total);
}

double _roundMoney(double value) {
  return (value * 100).roundToDouble() / 100;
}
