import '../../core/i18n/menu_localization.dart';

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

  String localizedName(String languageCode) => localizedMenuName({
    'name': label,
    'name_ko': nameKo,
    'name_vi': nameVi,
    'name_en': nameEn,
  }, languageCode);
}

class TableOrderPreview {
  const TableOrderPreview({required this.orderId, required this.lines});

  final String orderId;
  final List<TableOrderPreviewLine> lines;

  int get itemCount => lines.fold<int>(0, (sum, line) => sum + line.quantity);
}
