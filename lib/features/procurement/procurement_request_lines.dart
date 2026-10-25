/// Use the recorded material code, retaining the registered code for old lines.
String procurementMaterialCode(Map line) {
  for (final key in ['product_code_snapshot', 'product_code']) {
    final code = line[key]?.toString().trim() ?? '';
    if (code.isNotEmpty) return code;
  }
  return '';
}

/// Presentation only: preserve source lines, IDs, hashes and approval order.
/// Reserved shortages stay first; each group uses material-code order.
List<Map<String, dynamic>> procurementSortedRequestLines(Iterable<Map> lines) {
  final indexed = lines.toList().asMap().entries.toList();
  indexed.sort((a, b) {
    bool shortage(Map line) =>
        (line['shortage_sources'] as List? ?? []).isNotEmpty;
    final shortageOrder =
        (shortage(b.value) ? 1 : 0) - (shortage(a.value) ? 1 : 0);
    if (shortageOrder != 0) return shortageOrder;
    final left = procurementMaterialCode(a.value).toUpperCase();
    final right = procurementMaterialCode(b.value).toUpperCase();
    if (left.isEmpty != right.isEmpty) return left.isEmpty ? 1 : -1;
    final codeOrder = left.compareTo(right);
    return codeOrder == 0 ? a.key.compareTo(b.key) : codeOrder;
  });
  return [for (final entry in indexed) Map<String, dynamic>.from(entry.value)];
}
