class TableOrderPreviewLine {
  const TableOrderPreviewLine({required this.label, required this.quantity});

  final String label;
  final int quantity;
}

class TableOrderPreview {
  const TableOrderPreview({required this.orderId, required this.lines});

  final String orderId;
  final List<TableOrderPreviewLine> lines;

  int get itemCount => lines.fold<int>(0, (sum, line) => sum + line.quantity);
}
