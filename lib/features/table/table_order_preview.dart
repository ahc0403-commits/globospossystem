class TableOrderPreviewLine {
  const TableOrderPreviewLine({
    required this.label,
    required this.quantity,
    this.nameKo,
    this.nameVi,
    this.nameEn,
  });

  final String label;
  final int quantity;
  final String? nameKo;
  final String? nameVi;
  final String? nameEn;

  String localizedName(String languageCode) {
    final localized = switch (languageCode) {
      'vi' => nameVi,
      'en' => nameEn,
      _ => nameKo,
    };
    final value = localized?.trim() ?? '';
    if (value.isNotEmpty) return value;
    return switch (languageCode) {
      'vi' => 'Món',
      'en' => 'Item',
      _ => '메뉴',
    };
  }
}

class TableOrderPreview {
  const TableOrderPreview({required this.orderId, required this.lines});

  final String orderId;
  final List<TableOrderPreviewLine> lines;

  int get itemCount => lines.fold<int>(0, (sum, line) => sum + line.quantity);
}
