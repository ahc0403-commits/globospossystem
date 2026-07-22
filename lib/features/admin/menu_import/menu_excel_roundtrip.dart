import 'dart:typed_data';

import 'package:excel/excel.dart';

import 'menu_excel_import.dart';

const menuRoundTripHeaders = <String>[
  '매장ID',
  '카테고리ID',
  '카테고리명(KO)',
  '카테고리명(VI)',
  '카테고리명(EN)',
  '카테고리순서',
  '메뉴ID',
  '메뉴명(KO)',
  '메뉴명(VI)',
  '메뉴명(EN)',
  '설명',
  '가격(VND)',
  '판매가능',
  'QR메뉴노출',
  '메뉴순서',
];

const _roundTripMarkers = <String>{'카테고리ID', '카테고리명(VI)', '메뉴ID', '메뉴명(VI)'};

class MenuRoundTripCategory {
  const MenuRoundTripCategory({
    required this.sourceRow,
    required this.storeId,
    required this.categoryId,
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.sortOrder,
  });

  final int sourceRow;
  final String storeId;
  final String categoryId;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final int sortOrder;

  Map<String, dynamic> toJson() => {
    'source_row': sourceRow,
    'store_id': storeId,
    'category_id': categoryId,
    'name_ko': nameKo,
    'name_vi': nameVi,
    'name_en': nameEn,
    'sort_order': sortOrder,
  };
}

class MenuRoundTripItem {
  const MenuRoundTripItem({
    required this.sourceRow,
    required this.storeId,
    required this.categoryId,
    required this.itemId,
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.description,
    required this.price,
    required this.isAvailable,
    required this.isVisiblePublic,
    required this.sortOrder,
  });

  final int sourceRow;
  final String storeId;
  final String categoryId;
  final String itemId;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final String? description;
  final double price;
  final bool isAvailable;
  final bool isVisiblePublic;
  final int sortOrder;

  Map<String, dynamic> toJson() => {
    'source_row': sourceRow,
    'store_id': storeId,
    'category_id': categoryId,
    'item_id': itemId,
    'name_ko': nameKo,
    'name_vi': nameVi,
    'name_en': nameEn,
    'description': description,
    'price': price,
    'is_available': isAvailable,
    'is_visible_public': isVisiblePublic,
    'sort_order': sortOrder,
  };
}

class MenuRoundTripWorkbook {
  const MenuRoundTripWorkbook({required this.categories, required this.items});

  final List<MenuRoundTripCategory> categories;
  final List<MenuRoundTripItem> items;

  int get categoryCount => categories.length;
  int get itemCount => items.length;
  Set<String> get storeIds => {
    ...categories.map((row) => row.storeId),
    ...items.map((row) => row.storeId),
  };
}

List<int> buildMenuRoundTripWorkbook({
  required String storeId,
  required List<Map<String, dynamic>> categories,
  required List<Map<String, dynamic>> items,
}) {
  if (storeId.trim().isEmpty) {
    throw ArgumentError.value(storeId, 'storeId', 'must not be empty');
  }

  final sortedCategories = [...categories]
    ..sort((left, right) {
      final sort = _mapInt(
        left['sort_order'],
      ).compareTo(_mapInt(right['sort_order']));
      return sort != 0
          ? sort
          : _mapText(left['id']).compareTo(_mapText(right['id']));
    });
  final categoryIds = sortedCategories
      .map((category) => _mapText(category['id']))
      .where((id) => id.isNotEmpty)
      .toSet();
  final orphanItem = items.any(
    (item) => !categoryIds.contains(_mapText(item['category_id'])),
  );
  if (orphanItem) {
    throw StateError('MENU_EXPORT_ITEM_CATEGORY_MISSING');
  }

  final excel = Excel.createExcel();
  excel.rename('Sheet1', menuImportSheetName);
  excel.setDefaultSheet(menuImportSheetName);
  final sheet = excel[menuImportSheetName];
  sheet.appendRow(menuRoundTripHeaders.map(TextCellValue.new).toList());

  for (final category in sortedCategories) {
    final categoryId = _requiredMapText(category, 'id');
    final categoryNameKo = _localizedMapText(category, 'name_ko');
    final categoryNameVi = _localizedMapText(category, 'name_vi');
    final categoryNameEn = _localizedMapText(category, 'name_en');
    final categorySortOrder = _mapInt(category['sort_order']);
    final categoryItems =
        items
            .where((item) => _mapText(item['category_id']) == categoryId)
            .toList()
          ..sort((left, right) {
            final sort = _mapInt(
              left['sort_order'],
            ).compareTo(_mapInt(right['sort_order']));
            return sort != 0
                ? sort
                : _mapText(left['id']).compareTo(_mapText(right['id']));
          });

    if (categoryItems.isEmpty) {
      sheet.appendRow([
        TextCellValue(storeId),
        TextCellValue(categoryId),
        TextCellValue(categoryNameKo),
        TextCellValue(categoryNameVi),
        TextCellValue(categoryNameEn),
        IntCellValue(categorySortOrder),
        ...List<CellValue>.generate(9, (_) => TextCellValue('')),
      ]);
      continue;
    }

    for (var itemIndex = 0; itemIndex < categoryItems.length; itemIndex++) {
      final item = categoryItems[itemIndex];
      final writesCategory = itemIndex == 0;
      final description = _mapText(item['description']);
      sheet.appendRow([
        TextCellValue(storeId),
        TextCellValue(categoryId),
        TextCellValue(writesCategory ? categoryNameKo : ''),
        TextCellValue(writesCategory ? categoryNameVi : ''),
        TextCellValue(writesCategory ? categoryNameEn : ''),
        writesCategory ? IntCellValue(categorySortOrder) : TextCellValue(''),
        TextCellValue(_requiredMapText(item, 'id')),
        TextCellValue(_localizedMapText(item, 'name_ko')),
        TextCellValue(_localizedMapText(item, 'name_vi')),
        TextCellValue(_localizedMapText(item, 'name_en')),
        TextCellValue(description),
        DoubleCellValue(_mapDouble(item['price'])),
        BoolCellValue(item['is_available'] == true),
        BoolCellValue(item['is_visible_public'] == true),
        IntCellValue(_mapInt(item['sort_order'])),
      ]);
    }
  }

  const widths = <double>[
    38,
    38,
    24,
    24,
    24,
    14,
    38,
    24,
    24,
    24,
    34,
    16,
    14,
    14,
    12,
  ];
  for (var index = 0; index < widths.length; index++) {
    sheet.setColumnWidth(index, widths[index]);
  }

  return excel.encode()!;
}

/// Returns `null` for the legacy one-language import template.
MenuRoundTripWorkbook? tryParseMenuRoundTripWorkbook(Uint8List bytes) {
  Excel excel;
  try {
    excel = Excel.decodeBytes(bytes);
  } catch (_) {
    return null;
  }
  final sheet = excel.tables[menuImportSheetName];
  if (sheet == null || sheet.rows.isEmpty) {
    return null;
  }

  final headerIndexes = <String, int>{};
  for (var index = 0; index < sheet.rows.first.length; index++) {
    final header = _cellText(sheet.rows.first[index]?.value).trim();
    if (header.isNotEmpty) headerIndexes[header] = index;
  }
  if (!_roundTripMarkers.any(headerIndexes.containsKey)) {
    return null;
  }
  final missing = menuRoundTripHeaders
      .where((header) => !headerIndexes.containsKey(header))
      .toList();
  if (missing.isNotEmpty) {
    throw MenuImportValidationException([
      '일괄수정 필수 열이 없습니다: ${missing.join(', ')}',
    ]);
  }

  final issues = <String>[];
  final categories = <String, MenuRoundTripCategory>{};
  final items = <MenuRoundTripItem>[];
  final itemIds = <String>{};

  for (var index = 1; index < sheet.rows.length; index++) {
    final sourceRow = index + 1;
    final cells = sheet.rows[index];
    String text(String header) =>
        _cellText(_cellValueAt(cells, headerIndexes[header]!)).trim();

    final storeId = text('매장ID');
    final categoryId = text('카테고리ID');
    final categoryNameKo = text('카테고리명(KO)');
    final categoryNameVi = text('카테고리명(VI)');
    final categoryNameEn = text('카테고리명(EN)');
    final rawCategorySort = text('카테고리순서');
    final itemId = text('메뉴ID');
    final itemNameKo = text('메뉴명(KO)');
    final itemNameVi = text('메뉴명(VI)');
    final itemNameEn = text('메뉴명(EN)');
    final description = text('설명');
    final rawPrice = text('가격(VND)');
    final rawAvailable = text('판매가능');
    final rawPublic = text('QR메뉴노출');
    final rawItemSort = text('메뉴순서');

    if ([
      storeId,
      categoryId,
      categoryNameKo,
      categoryNameVi,
      categoryNameEn,
      itemId,
      itemNameKo,
      itemNameVi,
      itemNameEn,
      description,
      rawPrice,
    ].every((value) => value.isEmpty)) {
      continue;
    }

    if (!_isUuid(storeId)) {
      issues.add('$sourceRow행: 매장ID가 올바르지 않습니다.');
    }
    if (!_isUuid(categoryId)) {
      issues.add('$sourceRow행: 카테고리ID가 올바르지 않습니다.');
    }
    final hasAnyCategoryValue = [
      categoryNameKo,
      categoryNameVi,
      categoryNameEn,
      rawCategorySort,
    ].any((value) => value.isNotEmpty);
    if (hasAnyCategoryValue) {
      _validateName(categoryNameKo, sourceRow, '카테고리명(KO)', issues);
      _validateName(categoryNameVi, sourceRow, '카테고리명(VI)', issues);
      _validateName(categoryNameEn, sourceRow, '카테고리명(EN)', issues);
      final categorySortOrder = rawCategorySort.isEmpty
          ? null
          : _parseNonNegativeInt(rawCategorySort);
      if (categorySortOrder == null) {
        issues.add('$sourceRow행: 카테고리순서는 0 이상의 정수여야 합니다.');
      }

      if (_isUuid(storeId) &&
          _isUuid(categoryId) &&
          categoryNameKo.isNotEmpty &&
          categoryNameVi.isNotEmpty &&
          categoryNameEn.isNotEmpty &&
          categorySortOrder != null) {
        final category = MenuRoundTripCategory(
          sourceRow: sourceRow,
          storeId: storeId,
          categoryId: categoryId,
          nameKo: categoryNameKo,
          nameVi: categoryNameVi,
          nameEn: categoryNameEn,
          sortOrder: categorySortOrder,
        );
        final existing = categories[categoryId];
        if (existing != null &&
            (existing.storeId != category.storeId ||
                existing.nameKo != category.nameKo ||
                existing.nameVi != category.nameVi ||
                existing.nameEn != category.nameEn ||
                existing.sortOrder != category.sortOrder)) {
          issues.add('$sourceRow행: 같은 카테고리ID의 정보가 다른 행과 일치하지 않습니다.');
        } else {
          categories[categoryId] = category;
        }
      }
    }

    final hasAnyItemValue = [
      itemId,
      itemNameKo,
      itemNameVi,
      itemNameEn,
      description,
      rawPrice,
      rawAvailable,
      rawPublic,
      rawItemSort,
    ].any((value) => value.isNotEmpty);
    if (!hasAnyItemValue) continue;

    if (!_isUuid(itemId)) {
      issues.add('$sourceRow행: 메뉴ID가 올바르지 않습니다.');
    }
    _validateName(itemNameKo, sourceRow, '메뉴명(KO)', issues);
    _validateName(itemNameVi, sourceRow, '메뉴명(VI)', issues);
    _validateName(itemNameEn, sourceRow, '메뉴명(EN)', issues);
    if (description.length > 1000) {
      issues.add('$sourceRow행: 설명은 1000자 이하여야 합니다.');
    }
    final price = _parseNumber(rawPrice);
    if (price == null || price <= 0) {
      issues.add('$sourceRow행: 가격은 0보다 큰 숫자여야 합니다.');
    }
    final isAvailable = _parseBool(rawAvailable);
    if (isAvailable == null) {
      issues.add('$sourceRow행: 판매가능은 TRUE 또는 FALSE여야 합니다.');
    }
    final isVisiblePublic = _parseBool(rawPublic);
    if (isVisiblePublic == null) {
      issues.add('$sourceRow행: QR메뉴노출은 TRUE 또는 FALSE여야 합니다.');
    }
    final itemSortOrder = _parseNonNegativeInt(rawItemSort);
    if (itemSortOrder == null) {
      issues.add('$sourceRow행: 메뉴순서는 0 이상의 정수여야 합니다.');
    }
    if (itemId.isNotEmpty && !itemIds.add(itemId)) {
      issues.add('$sourceRow행: 같은 메뉴ID가 두 번 이상 있습니다.');
    }

    if (_isUuid(storeId) &&
        _isUuid(categoryId) &&
        _isUuid(itemId) &&
        itemNameKo.isNotEmpty &&
        itemNameVi.isNotEmpty &&
        itemNameEn.isNotEmpty &&
        price != null &&
        price > 0 &&
        isAvailable != null &&
        isVisiblePublic != null &&
        itemSortOrder != null) {
      items.add(
        MenuRoundTripItem(
          sourceRow: sourceRow,
          storeId: storeId,
          categoryId: categoryId,
          itemId: itemId,
          nameKo: itemNameKo,
          nameVi: itemNameVi,
          nameEn: itemNameEn,
          description: description.isEmpty ? null : description,
          price: price,
          isAvailable: isAvailable,
          isVisiblePublic: isVisiblePublic,
          sortOrder: itemSortOrder,
        ),
      );
    }
  }

  if (categories.isEmpty) {
    issues.add('수정할 카테고리가 없습니다.');
  }
  if (items.length > menuImportMaxRows) {
    issues.add('한 번에 최대 $menuImportMaxRows개 메뉴만 수정할 수 있습니다.');
  }
  for (final item in items) {
    if (!categories.containsKey(item.categoryId)) {
      issues.add('${item.sourceRow}행: 카테고리 다국어 정보가 파일에 없습니다.');
    }
  }
  final storeIds = {
    ...categories.values.map((row) => row.storeId),
    ...items.map((row) => row.storeId),
  };
  if (storeIds.length > 1) {
    issues.add('매장ID는 파일 전체에서 하나만 사용하세요.');
  }
  if (issues.isNotEmpty) {
    throw MenuImportValidationException(issues);
  }

  return MenuRoundTripWorkbook(
    categories: List.unmodifiable(categories.values),
    items: List.unmodifiable(items),
  );
}

CellValue? _cellValueAt(List<Data?> row, int index) {
  if (index < 0 || index >= row.length) {
    return null;
  }
  return row[index]?.value;
}

String _cellText(CellValue? value) => switch (value) {
  null => '',
  TextCellValue value => value.value.toString(),
  IntCellValue value => value.value.toString(),
  DoubleCellValue value => value.value.toString(),
  BoolCellValue value => value.value.toString().toUpperCase(),
  FormulaCellValue value => value.formula,
  _ => value.toString(),
};

String _mapText(Object? value) => value?.toString().trim() ?? '';

String _requiredMapText(Map<String, dynamic> row, String key) {
  final value = _mapText(row[key]);
  if (value.isEmpty) {
    throw StateError('MENU_EXPORT_${key.toUpperCase()}_MISSING');
  }
  return value;
}

String _localizedMapText(Map<String, dynamic> row, String key) {
  final value = _mapText(row[key]);
  if (value.isNotEmpty) {
    return value;
  }
  return _requiredMapText(row, 'name');
}

int _mapInt(Object? value) => switch (value) {
  int value => value,
  num value => value.toInt(),
  String value => int.tryParse(value) ?? 0,
  _ => 0,
};

double _mapDouble(Object? value) => switch (value) {
  num value => value.toDouble(),
  String value => double.tryParse(value) ?? 0,
  _ => 0,
};

double? _parseNumber(String value) {
  if (value.isEmpty) {
    return null;
  }
  return double.tryParse(value.replaceAll(',', '').replaceAll(' ', ''));
}

int? _parseNonNegativeInt(String value) {
  if (value.isEmpty) {
    return 0;
  }
  final parsed = _parseNumber(value);
  if (parsed == null || parsed < 0 || parsed != parsed.roundToDouble()) {
    return null;
  }
  return parsed.toInt();
}

bool? _parseBool(String value) => switch (value.trim().toUpperCase()) {
  'TRUE' || '1' || '예' || 'Y' || 'YES' => true,
  'FALSE' || '0' || '아니오' || 'N' || 'NO' => false,
  _ => null,
};

void _validateName(
  String value,
  int sourceRow,
  String label,
  List<String> issues,
) {
  if (value.isEmpty) {
    issues.add('$sourceRow행: $label을 입력하세요.');
  } else if (value.length > 200) {
    issues.add('$sourceRow행: $label은 200자 이하여야 합니다.');
  }
}

bool _isUuid(String value) => RegExp(
  r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[1-8][0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$',
).hasMatch(value);
