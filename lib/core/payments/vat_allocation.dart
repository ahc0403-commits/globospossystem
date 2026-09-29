/// Shares an amount in cents by weights, using the same remainder order as SQL.
List<int> allocateVatCents(int cents, List<int> weights) {
  final total = weights.fold<BigInt>(
    BigInt.zero,
    (sum, weight) => sum + BigInt.from(weight),
  );
  if (total <= BigInt.zero) return List.filled(weights.length, 0);
  final products = weights
      .map((weight) => BigInt.from(cents) * BigInt.from(weight))
      .toList();
  final result = products.map((product) => (product ~/ total).toInt()).toList();
  final order = List.generate(weights.length, (index) => index)
    ..sort((a, b) {
      final diff = (products[b] % total).compareTo(products[a] % total);
      return diff == 0 ? a.compareTo(b) : diff;
    });
  final remainder = cents - result.fold<int>(0, (sum, value) => sum + value);
  for (var i = 0; i < remainder; i++) {
    result[order[i]]++;
  }
  return result;
}

class VatPortion {
  const VatPortion({
    required this.rate,
    required this.supply,
    required this.vat,
    required this.total,
  });
  final double rate;
  final double supply;
  final double vat;
  final double total;
}

int _roundedRatio(int amount, int multiplier, int divisor) {
  final numerator = BigInt.from(amount) * BigInt.from(multiplier);
  final denominator = BigInt.from(divisor);
  return ((numerator * BigInt.two + denominator) ~/ (denominator * BigInt.two))
      .toInt();
}

double _number(Object? value) =>
    value is num ? value.toDouble() : double.parse(value.toString());

List<VatPortion> calculateItemVat({
  required List<Map<String, dynamic>> profile,
  required double amount,
  required String pricingMode,
  double discount = 0,
}) {
  final grouped = <double, int>{};
  for (final entry in profile) {
    final rate = _number(entry['rate']);
    final weight = _number(entry['weight']);
    if (![0.0, 8.0, 10.0].contains(rate) || !weight.isFinite || weight <= 0) {
      throw ArgumentError('Invalid VAT profile');
    }
    grouped[rate] = (grouped[rate] ?? 0) + (weight * 100).round();
  }
  if (grouped.isEmpty ||
      !amount.isFinite ||
      amount < 0 ||
      !discount.isFinite ||
      discount < 0 ||
      !['inclusive', 'exclusive'].contains(pricingMode)) {
    throw ArgumentError('Invalid VAT amount');
  }
  final rates = grouped.keys.toList()..sort();
  final allocations = allocateVatCents(
    (amount * 100).round(),
    rates.map((r) => grouped[r]!).toList(),
  );
  final grossCents = <int>[];
  for (var i = 0; i < rates.length; i++) {
    final gross = pricingMode == 'inclusive'
        ? allocations[i]
        : allocations[i] + _roundedRatio(allocations[i], rates[i].toInt(), 100);
    grossCents.add(gross);
  }
  final totalCents = grossCents.fold<int>(0, (sum, value) => sum + value);
  final discounts = allocateVatCents(
    (discount * 100).round().clamp(0, totalCents),
    grossCents,
  );
  return List.generate(rates.length, (i) {
    final netCents = grossCents[i] - discounts[i];
    final supplyCents = _roundedRatio(netCents, 100, 100 + rates[i].toInt());
    return VatPortion(
      rate: rates[i],
      supply: supplyCents / 100,
      vat: (netCents - supplyCents) / 100,
      total: netCents / 100,
    );
  });
}
