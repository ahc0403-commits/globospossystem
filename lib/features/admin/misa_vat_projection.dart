/// A bounded export-only allocation. Original receipt amounts are never changed.
typedef MisaVatLine = ({double supply, double rate, double vat});

bool misaVatLineMatches(MisaVatLine line) =>
    (line.supply * line.rate / 100).round() == line.vat.round();

/// Returns null unless all lines can be represented without changing any line's
/// gross or any receipt/rate's supply and VAT totals. Only cent-sized source
/// discrepancies at a rounding boundary are eligible for redistribution.
List<MisaVatLine>? projectMisaVatLines(List<MisaVatLine> source) {
  if (source.any(
    (l) =>
        !l.supply.isFinite ||
        !l.vat.isFinite ||
        !l.rate.isFinite ||
        !(l.supply * l.rate / 100).isFinite ||
        !(l.supply * 100).isFinite ||
        !(l.vat * 100).isFinite ||
        l.supply < 0 ||
        l.vat < 0 ||
        l.rate < 0 ||
        l.rate > 100,
  )) {
    return null;
  }
  final result = [...source];
  final groups = <double, List<int>>{};
  for (var i = 0; i < source.length; i++) {
    groups.putIfAbsent(source[i].rate, () => []).add(i);
  }
  for (final indexes in groups.values) {
    final supply = indexes.fold<double>(0, (n, i) => n + source[i].supply);
    final vat = indexes.fold<double>(0, (n, i) => n + source[i].vat);
    if (!supply.isFinite ||
        !vat.isFinite ||
        !(supply * source[indexes.first].rate / 100).isFinite) {
      return null;
    }
    if ((supply * source[indexes.first].rate / 100).round() != vat.round()) {
      return null;
    }
    if (indexes.every((i) => misaVatLineMatches(source[i]))) continue;
    if (indexes.any(
      (i) =>
          !misaVatLineMatches(source[i]) &&
          (source[i].vat - source[i].supply * source[i].rate / 100).abs() >
              0.0100001,
    )) {
      return null;
    }
    // Work in integer hundredths, with at most 0.10 VND per line. Refuse
    // non-cent source amounts instead of silently changing their precision.
    if (indexes.any(
      (i) =>
          (source[i].supply * 100 - (source[i].supply * 100).round()).abs() >
              0.00001 ||
          (source[i].vat * 100 - (source[i].vat * 100).round()).abs() > 0.00001,
    )) {
      return null;
    }
    final options = <int, List<int>>{};
    for (final i in indexes) {
      final l = source[i];
      final candidates = <int>[];
      for (var d = -10; d <= 10; d++) {
        final s = ((l.supply * 100).round() - d) / 100;
        final v = ((l.vat * 100).round() + d) / 100;
        if (s >= 0 &&
            v >= 0 &&
            misaVatLineMatches((supply: s, rate: l.rate, vat: v))) {
          candidates.add(d);
        }
      }
      if (candidates.isEmpty) return null;
      candidates.sort(
        (a, b) =>
            a.abs() != b.abs() ? a.abs().compareTo(b.abs()) : a.compareTo(b),
      );
      options[i] = candidates;
    }
    final chosen = {for (final i in indexes) i: options[i]!.first};
    var balance = chosen.values.fold<int>(0, (n, d) => n + d);
    for (final i in indexes) {
      if (balance == 0) break;
      final old = chosen[i]!;
      final choices =
          options[i]!.where((d) => balance > 0 ? d < old : d > old).toList()
            ..sort(
              (a, b) => (balance + a - old).abs().compareTo(
                (balance + b - old).abs(),
              ),
            );
      if (choices.isNotEmpty &&
          (balance + choices.first - old).abs() < balance.abs()) {
        chosen[i] = choices.first;
        balance += choices.first - old;
      }
    }
    if (balance != 0) return null;
    for (final i in indexes) {
      final l = source[i], d = chosen[i]!;
      result[i] = (
        supply: ((l.supply * 100).round() - d) / 100,
        rate: l.rate,
        vat: ((l.vat * 100).round() + d) / 100,
      );
    }
  }
  return result;
}
