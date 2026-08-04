double? parseDecimalInput(String? value) {
  final normalized = value?.trim().replaceAll(',', '') ?? '';
  if (normalized.isEmpty) return null;
  return double.tryParse(normalized);
}

/// Parses physical quantities entered with either a dot or a comma decimal
/// separator. Unlike currency parsing, a single comma is a decimal separator:
/// `1,5` means 1.5, never 15.
double? parseLocalizedQuantityInput(String? value) {
  final raw = value?.trim().replaceAll(' ', '') ?? '';
  if (raw.isEmpty || raw.contains(RegExp(r'[^0-9,.-]'))) return null;
  if ('-'.allMatches(raw).length > 1 ||
      (raw.contains('-') && !raw.startsWith('-'))) {
    return null;
  }

  final commaCount = ','.allMatches(raw).length;
  final dotCount = '.'.allMatches(raw).length;
  if (commaCount > 1 || dotCount > 1 || (commaCount > 0 && dotCount > 0)) {
    return null;
  }

  final normalized = raw.replaceAll(',', '.');
  final decimalPart = normalized.split('.');
  if (decimalPart.length == 2 && decimalPart.last.length > 3) return null;
  return double.tryParse(normalized);
}

int? parseIntInput(String? value) {
  final normalized = value?.trim().replaceAll(',', '') ?? '';
  if (normalized.isEmpty) return null;
  return int.tryParse(normalized);
}
