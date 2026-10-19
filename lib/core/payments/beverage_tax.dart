/// 2026 VAT classification for soft drinks covered by the labelled-sugar rule.
/// Product identity and the existing food/alcohol category stay independent.
class BeverageTax {
  const BeverageTax({
    this.sugarClass = 'not_applicable',
    this.sugarGrams,
    this.basisNote = '',
  });

  final String sugarClass;
  final double? sugarGrams;
  final String basisNote;

  factory BeverageTax.fromJson(Map<String, dynamic> json) => BeverageTax(
    sugarClass:
        json['beverage_sugar_tax_class']?.toString() ?? 'not_applicable',
    sugarGrams: switch (json['sugar_g_per_100ml']) {
      num value => value.toDouble(),
      String value => double.tryParse(value),
      _ => null,
    },
    basisNote: json['tax_basis_note']?.toString() ?? '',
  );

  bool get isApplicable => sugarClass != 'not_applicable';

  bool get isValid =>
      const ['not_applicable', 'lte_5', 'gt_5'].contains(sugarClass) &&
      basisNote.length <= 500 &&
      (sugarGrams == null ||
          (sugarGrams!.isFinite && sugarGrams! >= 0 && sugarGrams! <= 100)) &&
      (!isApplicable
          ? sugarGrams == null
          : sugarGrams == null
          ? basisNote.trim().isNotEmpty
          : sugarClass == (sugarGrams! > 5 ? 'gt_5' : 'lte_5'));

  double vatRate({String? vatCategory}) =>
      vatCategory == 'alcohol' || sugarClass == 'gt_5' ? 10 : 8;

  Map<String, dynamic> toJson() => {
    'beverage_sugar_tax_class': sugarClass,
    'sugar_g_per_100ml': sugarGrams,
    'tax_basis_note': basisNote.trim(),
  };
}
