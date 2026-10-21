import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';

/// The catalog revision is an opaque server key. Display hints are only for
/// offline carts: the server calculates all prices/labels from its definition.
class MenuChoiceCatalog {
  MenuChoiceCatalog(this.key, this.definition, this.basePrice, this.legacyKey);
  final String key;
  final Map<String, dynamic> definition;
  final double basePrice;
  final String? legacyKey;
  String get revision => md5.convert(utf8.encode(key)).toString();
  List<Map<String, dynamic>> groups(String channel) =>
      (definition['groups'] as List)
          .cast<Map<String, dynamic>>()
          .where((g) => (g['channels'] as List).contains(channel))
          .toList();
  static MenuChoiceCatalog? fromKey(String? key) {
    if (key == null) return null;
    try {
      final value = jsonDecode(key);
      if (value is! Map<String, dynamic> ||
          value['schema'] != 2 ||
          value['definition'] is! Map<String, dynamic>) {
        return null;
      }
      return MenuChoiceCatalog(
        key,
        value['definition'],
        (value['base_price'] as num).toDouble(),
        value['legacy_key'] as String?,
      );
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Map<String, int> defaults(String channel) => {
    for (final g in groups(channel))
      for (final v in (g['values'] as List).cast<Map<String, dynamic>>())
        if (v['available'] == true && (v['default_quantity'] as num? ?? 0) > 0)
          v['id'] as String: (v['default_quantity'] as num).toInt(),
  };

  bool valid(Map<String, int> selected, String channel) {
    final allowed = <String, Map<String, dynamic>>{};
    for (final g in groups(channel)) {
      var count = 0;
      for (final v in (g['values'] as List).cast<Map<String, dynamic>>()) {
        final id = v['id'] as String;
        allowed[id] = v;
        final quantity = selected[id] ?? 0;
        if (quantity < 0 ||
            quantity > 8 ||
            (quantity > 0 && v['available'] != true) ||
            (g['repeat'] != true && quantity > 1)) {
          return false;
        }
        count += quantity;
      }
      if (count < (g['min'] as num) || count > (g['max'] as num)) return false;
    }
    if (selected.keys.any((id) => !allowed.containsKey(id))) return false;
    for (final r in (definition['rules'] as List? ?? const [])) {
      if ((selected[r['from']] ?? 0) == 0) continue;
      final to = (selected[r['to']] ?? 0) > 0;
      if ((r['kind'] == 'requires' && !to) || (r['kind'] == 'excludes' && to)) {
        return false;
      }
    }
    return true;
  }

  MenuChoiceSelection select(Map<String, int> selected, String channel) {
    if (!valid(selected, channel)) {
      throw const FormatException('MENU_SELECTION_INVALID');
    }
    var price = basePrice;
    final labels = <String, List<String>>{'ko': [], 'vi': [], 'en': []};
    final choices = <Map<String, dynamic>>[];
    for (final g in groups(channel)) {
      for (final v in (g['values'] as List).cast<Map<String, dynamic>>()) {
        final quantity = selected[v['id']] ?? 0;
        if (quantity == 0) continue;
        choices.add({'value_id': v['id'], 'quantity': quantity});
        price += (v['price_delta'] as num).toDouble() * quantity;
        for (final language in labels.keys) {
          labels[language]!.add(
            '${v['name_$language']}${quantity > 1 ? ' ×$quantity' : ''}',
          );
        }
      }
    }
    return MenuChoiceSelection(
      jsonEncode({
        'schema': 2,
        'revision': revision,
        'selected': choices,
        'legacy_key': legacyKey,
        'unit_price': price,
        'labels': labels.map((k, v) => MapEntry(k, v.join(' · '))),
      }),
    );
  }
}

class MenuChoiceSelection {
  MenuChoiceSelection(this.key)
    : data = jsonDecode(key) as Map<String, dynamic>;
  final String key;
  final Map<String, dynamic> data;
  double get price => (data['unit_price'] as num).toDouble();
  Map<String, int> get selected => {
    for (final v in data['selected'] as List)
      v['value_id'] as String: (v['quantity'] as num).toInt(),
  };
  String label(String language) =>
      (data['labels'] as Map?)?[language]?.toString() ?? '';
  String name(String base, String language) =>
      label(language).isEmpty ? base : '$base [${label(language)}]';
  String lineId(String menuId) =>
      '${menuChoiceBaseId(menuId)}~${md5.convert(utf8.encode(key))}';
  static MenuChoiceSelection? fromKey(String? key) {
    if (key == null) return null;
    try {
      final value = jsonDecode(key);
      if (value is! Map ||
          value['schema'] != 2 ||
          value['selected'] is! List ||
          value['unit_price'] is! num ||
          value['revision'] is! String) {
        return null;
      }
      final selected = value['selected'] as List;
      if (selected.length > 64 ||
          selected.any(
            (v) =>
                v is! Map ||
                v['value_id'] is! String ||
                v['quantity'] is! int ||
                (v['quantity'] as int) < 1 ||
                (v['quantity'] as int) > 8,
          ) ||
          selected.map((v) => v['value_id']).toSet().length !=
              selected.length ||
          !(value['unit_price'] as num).isFinite ||
          (value['unit_price'] as num) < 0 ||
          value['labels'] is! Map) {
        return null;
      }
      return MenuChoiceSelection(key);
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }
}

String menuChoiceBaseId(String lineId) => lineId.split('~').first;
bool menuChoiceKeyMatches(String? selected, String? catalog) {
  final definition = MenuChoiceCatalog.fromKey(catalog);
  if (definition == null) return selected == catalog;
  return MenuChoiceSelection.fromKey(selected)?.data['revision'] ==
      definition.revision;
}

Future<MenuChoiceSelection?> showMenuChoicePicker(
  BuildContext context, {
  required String title,
  required MenuChoiceCatalog catalog,
  required String channel,
  required String language,
  String? initialKey,
}) {
  String text(String ko, String vi, String en) => switch (language) {
    'ko' => ko,
    'vi' => vi,
    _ => en,
  };
  final selected = Map<String, int>.of(
    MenuChoiceSelection.fromKey(initialKey)?.selected ??
        catalog.defaults(channel),
  );
  // Removed choices cannot survive an explicit reselection after a catalog edit.
  final ids = {
    for (final g in catalog.groups(channel))
      for (final v in g['values'] as List) v['id'],
  };
  selected.removeWhere((id, _) => !ids.contains(id));
  return showDialog<MenuChoiceSelection>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, update) => AlertDialog(
        key: const Key('menu_choice_picker'),
        title: Text(title),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final g in catalog.groups(channel)) ...[
                  Text(
                    '${g['name_$language'] ?? g['name_en']} (${g['min']}–${g['max']})',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                  for (final v
                      in (g['values'] as List).cast<Map<String, dynamic>>())
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text('${v['name_$language'] ?? v['name_en']}'),
                      subtitle: (v['price_delta'] as num) == 0
                          ? null
                          : Text('+${v['price_delta']} VND'),
                      enabled: v['available'] == true,
                      trailing: g['repeat'] == true
                          ? Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                IconButton(
                                  onPressed: (selected[v['id']] ?? 0) == 0
                                      ? null
                                      : () => update(() {
                                          final q = selected[v['id']]! - 1;
                                          if (q == 0) {
                                            selected.remove(v['id']);
                                          } else {
                                            selected[v['id']] = q;
                                          }
                                        }),
                                  icon: const Icon(Icons.remove),
                                ),
                                Text('${selected[v['id']] ?? 0}'),
                                IconButton(
                                  onPressed:
                                      v['available'] != true ||
                                          (selected[v['id']] ?? 0) >= 8
                                      ? null
                                      : () => update(
                                          () => selected[v['id']] =
                                              (selected[v['id']] ?? 0) + 1,
                                        ),
                                  icon: const Icon(Icons.add),
                                ),
                              ],
                            )
                          : Checkbox(
                              value: (selected[v['id']] ?? 0) > 0,
                              onChanged: v['available'] != true
                                  ? null
                                  : (enabled) => update(() {
                                      if (enabled != true) {
                                        selected.remove(v['id']);
                                        return;
                                      }
                                      if (g['max'] == 1) {
                                        for (final other
                                            in g['values'] as List) {
                                          selected.remove(other['id']);
                                        }
                                      }
                                      selected[v['id']] = 1;
                                    }),
                            ),
                    ),
                  const SizedBox(height: 16),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(text('취소', 'Hủy', 'Cancel')),
          ),
          FilledButton(
            key: const Key('menu_choice_confirm'),
            onPressed: !catalog.valid(selected, channel)
                ? null
                : () =>
                      Navigator.pop(context, catalog.select(selected, channel)),
            child: Text(text('선택 완료', 'Xác nhận', 'Confirm')),
          ),
        ],
      ),
    ),
  );
}
