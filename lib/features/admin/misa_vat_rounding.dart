/// Comparison only: never changes the source supply or VAT amount.
/// Source VAT is a two-decimal HALF_UP amount; compare like precision before
/// applying MISA's whole-VND comparison (e.g. 1200.4968 -> 1200.50 -> 1201).
bool misaSourceVatMatches(double supply, double rate, double vat) {
  if (![supply, rate, vat].every((n) => n.isFinite && n >= 0) || rate > 100) {
    return false;
  }
  return _matches(_Decimal.of(supply), _Decimal.of(rate), _Decimal.of(vat));
}

bool misaSourceVatSummaryMatches(
  Iterable<({double supply, double rate, double vat})> lines,
) {
  final totals = <double, ({_Decimal supply, _Decimal vat})>{};
  for (final line in lines) {
    if (![
          line.supply,
          line.rate,
          line.vat,
        ].every((n) => n.isFinite && n >= 0) ||
        line.rate > 100) {
      return false;
    }
    final prev = totals[line.rate];
    totals[line.rate] = (
      supply: (prev?.supply ?? _Decimal.zero).add(_Decimal.of(line.supply)),
      vat: (prev?.vat ?? _Decimal.zero).add(_Decimal.of(line.vat)),
    );
  }
  return totals.entries.every(
    (e) => _matches(e.value.supply, _Decimal.of(e.key), e.value.vat),
  );
}

bool _matches(_Decimal supply, _Decimal rate, _Decimal vat) {
  final expectedCents = _halfUp(
    supply.units * rate.units,
    supply.scale * rate.scale,
  );
  final actualCents = _halfUp(vat.units * BigInt.from(100), vat.scale);
  return (expectedCents + BigInt.from(50)) ~/ BigInt.from(100) ==
      (actualCents + BigInt.from(50)) ~/ BigInt.from(100);
}

BigInt _halfUp(BigInt numerator, BigInt denominator) =>
    (numerator * BigInt.two + denominator) ~/ (denominator * BigInt.two);

// Parse the decimal source representation, including scientific notation. This
// avoids binary floating-point moving an exact .495/.50 tie across a boundary.
class _Decimal {
  const _Decimal(this.units, this.scale);
  static final zero = _Decimal(BigInt.zero, BigInt.one);
  final BigInt units, scale;
  factory _Decimal.of(double value) {
    final parts = value.toString().toLowerCase().split('e');
    final coefficient = parts.first.split('.');
    final exponent = parts.length == 2 ? int.parse(parts[1]) : 0;
    final decimals = coefficient.length == 2 ? coefficient[1].length : 0;
    final units = BigInt.parse(coefficient.join());
    final power = decimals - exponent;
    return power >= 0
        ? _Decimal(units, BigInt.from(10).pow(power))
        : _Decimal(units * BigInt.from(10).pow(-power), BigInt.one);
  }
  _Decimal add(_Decimal other) {
    final common = scale > other.scale ? scale : other.scale;
    return _Decimal(
      units * (common ~/ scale) + other.units * (common ~/ other.scale),
      common,
    );
  }
}
