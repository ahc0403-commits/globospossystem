import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

/// One catalog dish owns its size prices. Existing sellable IDs are retained
/// only on the selected price so historical orders and invoice mappings survive.
class MenuSizeMetadata {
  const MenuSizeMetadata(this.menuId, this.names, this.size);
  final String menuId;
  final String size;
  final Map<String, dynamic> names;

  static MenuSizeMetadata? fromKey(String? key) {
    if (key == null) return null;
    try {
      final value = jsonDecode(key);
      if (value is! List || value.length != 5 || value[4] is! Map) return null;
      final data = Map<String, dynamic>.from(value[4] as Map);
      final id = data['menu_id'];
      final names = data['names'];
      if (id is! String || names is! Map || !['S', 'L'].contains(value[0])) {
        return null;
      }
      return MenuSizeMetadata(
        id,
        Map<String, dynamic>.from(names),
        value[0] as String,
      );
    } on FormatException {
      return null;
    }
  }
}

List<Map<String, dynamic>> menuCatalogRows(List<Map<String, dynamic>> rows) {
  final choices = <String, List<Map<String, dynamic>>>{};
  for (final row in rows) {
    final size = MenuSizeMetadata.fromKey(row['menu_option_key']?.toString());
    if (size != null) (choices[size.menuId] ??= []).add(row);
  }
  return [
    for (final row in rows)
      if (row['size_parent_id'] == null &&
          (MenuSizeMetadata.fromKey(
                    row['menu_option_key']?.toString(),
                  )?.menuId ??
                  row['id']) ==
              row['id'])
        if (choices[row['id']] case final options?)
          {
            ...row,
            ...MenuSizeMetadata.fromKey(
              row['menu_option_key']?.toString(),
            )!.names,
            'size_options': options,
          }
        else
          row,
  ];
}

class MenuSizeOption {
  const MenuSizeOption({
    required this.id,
    required this.size,
    required this.price,
  });
  final String id;
  final String size;
  final double price;
}

class MenuSizeSelection {
  const MenuSizeSelection(this.optionId, this.isTakeout);
  final String optionId;
  final bool isTakeout;
}

Future<MenuSizeSelection?> showMenuSizePicker(
  BuildContext context, {
  required String title,
  required List<MenuSizeOption> options,
  required String languageCode,
  bool allowTakeout = false,
}) {
  final money = NumberFormat('#,###', 'vi_VN');
  String text(String ko, String vi, String en) => switch (languageCode) {
    'ko' => ko,
    'vi' => vi,
    _ => en,
  };
  var takeout = false;
  return showDialog<MenuSizeSelection>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        key: const Key('menu_size_picker'),
        title: Text(title),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                text('사이즈를 선택해 주세요.', 'Vui lòng chọn cỡ.', 'Choose a size.'),
              ),
              if (allowTakeout)
                SwitchListTile(
                  title: Text(text('포장 주문', 'Mang đi', 'Takeout')),
                  value: takeout,
                  onChanged: (value) => setState(() => takeout = value),
                ),
              const SizedBox(height: 12),
              for (final option in options)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: OutlinedButton(
                    key: Key('menu_size_${option.size}'),
                    onPressed: () => Navigator.pop(
                      context,
                      MenuSizeSelection(option.id, takeout),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 12),
                      child: Text(
                        '${option.size} · ${money.format(option.price)} VND',
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(text('취소', 'Hủy', 'Cancel')),
          ),
        ],
      ),
    ),
  );
}
