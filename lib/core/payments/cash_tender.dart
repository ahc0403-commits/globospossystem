class CashTender {
  const CashTender({required this.amountDue, required this.receivedAmount});

  final double amountDue;
  final double receivedAmount;

  double get changeAmount => receivedAmount - amountDue;
  bool get isSufficient => amountDue > 0 && receivedAmount >= amountDue;
}

double? parseCashAmount(String input) {
  final normalized = input.replaceAll(RegExp(r'[^0-9]'), '');
  if (normalized.isEmpty) return null;
  return double.tryParse(normalized);
}
