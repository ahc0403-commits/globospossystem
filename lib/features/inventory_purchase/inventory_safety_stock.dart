/// Safety stock uses physical units, independently of purchase pack sizes.
class InventorySafetyStock {
  static double factor(String baseUnit) =>
      baseUnit == 'g' || baseUnit == 'ml' ? 1000 : 1;

  static String unit(String baseUnit) => switch (baseUnit) {
    'g' => 'kg',
    'ml' => 'L',
    _ => 'ea',
  };

  static double? baseQuantity(Object? value) => value is num
      ? value.toDouble()
      : double.tryParse(value?.toString() ?? '');

  static String input(Object? baseQuantity, String baseUnit) {
    final quantity = InventorySafetyStock.baseQuantity(baseQuantity);
    if (quantity == null) return '';
    return (quantity / factor(baseUnit))
        .toStringAsFixed(6)
        .replaceFirst(RegExp(r'\.?0+$'), '');
  }

  static double? parse(String input) {
    final raw = input.trim();
    if (!RegExp(r'^-?(?:\d+(?:[.,]\d{0,6})?|[.,]\d{1,6})$').hasMatch(raw)) {
      return null;
    }
    return double.tryParse(raw.replaceAll(',', '.'));
  }

  static double toBase(double displayedQuantity, String baseUnit) =>
      double.parse((displayedQuantity * factor(baseUnit)).toStringAsFixed(3));

  static bool isValid(double quantity, String baseUnit) =>
      quantity.isFinite &&
      quantity >= 0 &&
      quantity * factor(baseUnit) <= 999999999.999;

  static bool needsReorder(Object? currentStock, Object? safetyStock) {
    final current = baseQuantity(currentStock);
    final threshold = baseQuantity(safetyStock);
    return current != null && threshold != null && current <= threshold;
  }
}
