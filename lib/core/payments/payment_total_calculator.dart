const String vatPricingModeExclusive = 'exclusive';
const String vatPricingModeInclusive = 'inclusive';

({double supply, double vat, double total}) wetTissueAmounts({
  required double unitPrice,
  required int quantity,
  required String vatPricingMode,
}) {
  final price = _roundMoney(unitPrice * quantity);
  final supply = vatPricingMode == vatPricingModeInclusive
      ? _roundMoney(price / 1.08)
      : price;
  final vat = vatPricingMode == vatPricingModeInclusive
      ? _roundMoney(price - supply)
      : _roundMoney(supply * .08);
  return (supply: supply, vat: vat, total: _roundMoney(supply + vat));
}

class PaymentQuoteLine {
  const PaymentQuoteLine({
    this.id = '',
    required this.unitPrice,
    required this.quantity,
    required this.status,
    required this.itemType,
    this.isServiceItem = false,
    this.vatCategory,
    this.vatRate,
    this.payingAmountIncTax,
    this.discountAmount = 0,
  });

  final String id;
  final double unitPrice;
  final int quantity;
  final String status;
  final String itemType;
  final bool isServiceItem;
  final String? vatCategory;
  final double? vatRate;
  final double? payingAmountIncTax;
  final double discountAmount;
}

class PaymentQuoteResult {
  const PaymentQuoteResult({
    required this.menuSubtotal,
    required this.serviceChargeTotal,
    required this.serviceItemTotal,
    required this.fixedChargeTotal,
    required this.discountTotal,
    required this.vatTotal,
    required this.payableTotal,
  });

  final double menuSubtotal;
  final double serviceChargeTotal;
  final double serviceItemTotal;
  final double fixedChargeTotal;
  final double discountTotal;
  final double vatTotal;
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
  var existingServiceChargeVatTotal = 0.0;
  var serviceItemTotal = 0.0;
  var fixedChargeTotal = 0.0;
  var fixedChargeVatTotal = 0.0;
  var hasExistingServiceCharge = false;
  var explicitDiscountCents = 0;
  final menuVatLines = <_PaymentVatLine>[];

  for (final line in lines) {
    if (line.status.toLowerCase() == 'cancelled') {
      continue;
    }

    final itemType = line.itemType.toLowerCase();
    if (itemType == 'menu_item' && line.isServiceItem) {
      serviceItemTotal += _roundMoney(line.unitPrice * line.quantity);
      continue;
    }

    if (itemType != 'menu_item') {
      if (itemType == 'service_charge') {
        hasExistingServiceCharge = true;
        final serviceChargeIncTax =
            line.payingAmountIncTax != null && line.payingAmountIncTax! > 0
            ? line.payingAmountIncTax!
            : line.unitPrice * line.quantity;
        existingServiceChargeTotal += serviceChargeIncTax;
        final vatRate = line.vatRate ?? 0;
        if (vatRate > 0) {
          existingServiceChargeVatTotal +=
              serviceChargeIncTax -
              _roundMoney(serviceChargeIncTax / (1 + (vatRate / 100)));
        }
      } else if (itemType == 'wet_tissue_charge') {
        final amounts = wetTissueAmounts(
          unitPrice: line.unitPrice,
          quantity: line.quantity,
          vatPricingMode: vatPricingMode,
        );
        // A persisted payment snapshot remains authoritative for history.
        final gross = line.payingAmountIncTax ?? amounts.total;
        final rate = line.vatRate ?? 8;
        fixedChargeTotal += gross;
        fixedChargeVatTotal += gross - _roundMoney(gross / (1 + rate / 100));
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
    menuVatLines.add(
      _PaymentVatLine(
        id: line.id,
        incTaxCents: (incTax * 100).round(),
        vatRate: vatRate,
        explicitDiscountCents: (line.discountAmount * 100).round(),
      ),
    );
    explicitDiscountCents += (line.discountAmount * 100)
        .round()
        .clamp(0, (incTax * 100).round())
        .toInt();
    if (vatRate == 10.0) {
      alcoholPretaxSubtotal += pretax;
    } else {
      foodPretaxSubtotal += pretax;
    }
  }

  final generatedServiceCharge = _calculateGeneratedServiceCharge(
    enabled: serviceChargeEnabled && !hasExistingServiceCharge,
    rate: serviceChargeRate,
    foodPretaxSubtotal: foodPretaxSubtotal,
    alcoholPretaxSubtotal: alcoholPretaxSubtotal,
  );
  final serviceChargeTotal = hasExistingServiceCharge
      ? existingServiceChargeTotal
      : generatedServiceCharge.total;

  final hasExplicitDiscounts = explicitDiscountCents > 0;
  final resolvedDiscount = hasExplicitDiscounts
      ? _roundMoney(explicitDiscountCents / 100)
      : _roundMoney(discountTotal.clamp(0, menuSubtotal).toDouble());
  final menuVatTotal = _calculateDiscountedMenuVat(
    menuVatLines,
    discountCents: (resolvedDiscount * 100).round(),
    useExplicitDiscounts: hasExplicitDiscounts,
  );
  final serviceChargeVatTotal = hasExistingServiceCharge
      ? existingServiceChargeVatTotal
      : generatedServiceCharge.vat;

  return PaymentQuoteResult(
    menuSubtotal: _roundMoney(menuSubtotal),
    serviceChargeTotal: _roundMoney(serviceChargeTotal),
    serviceItemTotal: _roundMoney(serviceItemTotal),
    fixedChargeTotal: _roundMoney(fixedChargeTotal),
    discountTotal: resolvedDiscount,
    vatTotal: _roundMoney(
      menuVatTotal + serviceChargeVatTotal + fixedChargeVatTotal,
    ),
    payableTotal: _roundMoney(
      menuSubtotal + serviceChargeTotal + fixedChargeTotal - resolvedDiscount,
    ),
  );
}

({double total, double vat}) _calculateGeneratedServiceCharge({
  required bool enabled,
  required double rate,
  required double foodPretaxSubtotal,
  required double alcoholPretaxSubtotal,
}) {
  if (!enabled || rate <= 0) {
    return (total: 0, vat: 0);
  }

  var total = 0.0;
  var vat = 0.0;
  if (foodPretaxSubtotal > 0) {
    final pretax = _roundMoney(foodPretaxSubtotal * rate / 100);
    final vatAmount = _roundMoney(pretax * 8 / 100);
    vat += vatAmount;
    total += pretax + vatAmount;
  }
  if (alcoholPretaxSubtotal > 0) {
    final pretax = _roundMoney(alcoholPretaxSubtotal * rate / 100);
    final vatAmount = _roundMoney(pretax * 10 / 100);
    vat += vatAmount;
    total += pretax + vatAmount;
  }
  return (total: _roundMoney(total), vat: _roundMoney(vat));
}

double _calculateDiscountedMenuVat(
  List<_PaymentVatLine> lines, {
  required int discountCents,
  bool useExplicitDiscounts = false,
}) {
  final menuTotalCents = lines.fold<int>(
    0,
    (total, line) => total + line.incTaxCents,
  );
  if (menuTotalCents <= 0) return 0;

  final cappedDiscountCents = discountCents.clamp(0, menuTotalCents).toInt();
  final allocations = <_DiscountAllocation>[];
  if (useExplicitDiscounts) {
    for (final line in lines) {
      allocations.add(
        _DiscountAllocation(
          line: line,
          cents: line.explicitDiscountCents.clamp(0, line.incTaxCents).toInt(),
          fraction: 0,
        ),
      );
    }
  } else {
    var allocatedCents = 0;
    for (final line in lines) {
      final exact = cappedDiscountCents * line.incTaxCents / menuTotalCents;
      final base = exact.floor();
      allocatedCents += base;
      allocations.add(
        _DiscountAllocation(line: line, cents: base, fraction: exact - base),
      );
    }

    allocations.sort((left, right) {
      final fractionOrder = right.fraction.compareTo(left.fraction);
      if (fractionOrder != 0) return fractionOrder;
      return left.line.id.compareTo(right.line.id);
    });
    final remainder = cappedDiscountCents - allocatedCents;
    for (var index = 0; index < remainder; index++) {
      allocations[index].cents += 1;
    }
  }

  var vatTotal = 0.0;
  for (final allocation in allocations) {
    final incTaxCents = allocation.line.incTaxCents - allocation.cents;
    final incTax = (incTaxCents < 0 ? 0 : incTaxCents) / 100;
    final pretax = _roundMoney(incTax / (1 + (allocation.line.vatRate / 100)));
    vatTotal += incTax - pretax;
  }
  return _roundMoney(vatTotal);
}

class _PaymentVatLine {
  const _PaymentVatLine({
    required this.id,
    required this.incTaxCents,
    required this.vatRate,
    this.explicitDiscountCents = 0,
  });

  final String id;
  final int incTaxCents;
  final double vatRate;
  final int explicitDiscountCents;
}

class _DiscountAllocation {
  _DiscountAllocation({
    required this.line,
    required this.cents,
    required this.fraction,
  });

  final _PaymentVatLine line;
  int cents;
  final double fraction;
}

double _roundMoney(double value) {
  return (value * 100).roundToDouble() / 100;
}
