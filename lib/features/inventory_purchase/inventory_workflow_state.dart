/// Shared UI/query contract. Every known status remains discoverable.
enum InventoryOrderGroup {
  pending(['draft', 'submitted', 'store_approved', 'office_returned']),
  placed(['ordered', 'partially_received', 'received', 'office_approved']),
  cancelled(['cancelled']),
  rejected(['office_rejected']),
  review(['brand_approved']);

  const InventoryOrderGroup(this.statuses);
  final List<String> statuses;

  int count(Map<String, dynamic> counts) => statuses.fold(
    0,
    (sum, status) => sum + ((counts[status] as num?)?.toInt() ?? 0),
  );
}

/// Blank and invalid input must not silently turn into a zero delivery.
double? parseInventoryQuantity(String text) {
  final cleaned = text.trim().replaceAll(',', '');
  if (cleaned.isEmpty) return null;
  final value = double.tryParse(cleaned);
  return value != null && value.isFinite && value >= 0 ? value : null;
}
