import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../services/pos_backend.dart';

/// Edits a bounded definition locally; the parent menu registration saves the
/// definition, prices and legacy size projections in the same transaction.
class MenuChoiceEditor extends StatelessWidget {
  const MenuChoiceEditor({
    super.key,
    required this.definition,
    required this.onChanged,
    this.storeId,
  });
  final Map<String, dynamic>? definition;
  final ValueChanged<Map<String, dynamic>> onChanged;
  final String? storeId;
  @override
  Widget build(BuildContext context) {
    final lang = Localizations.localeOf(context).languageCode;
    String text(String ko, String vi, String en) => switch (lang) {
      'ko' => ko,
      'vi' => vi,
      _ => en,
    };
    final groups = (definition?['groups'] as List? ?? const []);
    return ListTile(
      title: Text(text('고객 선택 옵션', 'Tùy chọn của khách', 'Customer choices')),
      subtitle: Text(
        text(
          '${groups.length}개 선택군 · 맵기, 짜기, 사이즈, 추가 재료',
          '${groups.length} nhóm · độ cay, độ mặn, cỡ, thêm nguyên liệu',
          '${groups.length} groups · spice, salt, size, additions',
        ),
      ),
      trailing: const Icon(Icons.tune),
      onTap: () async {
        final result = await showDialog<Map<String, dynamic>>(
          context: context,
          builder: (_) => _DefinitionDialog(
            initial: definition ?? const {},
            storeId: storeId,
          ),
        );
        if (result != null) onChanged(result);
      },
    );
  }
}

class _DefinitionDialog extends StatefulWidget {
  const _DefinitionDialog({required this.initial, this.storeId});
  final Map<String, dynamic> initial;
  final String? storeId;
  @override
  State<_DefinitionDialog> createState() => _DefinitionDialogState();
}

class _DefinitionDialogState extends State<_DefinitionDialog> {
  final form = GlobalKey<FormState>();
  late final List<Map<String, dynamic>> groups;
  late final List<Map<String, dynamic>> rules;
  final ingredientNames = <String, String>{};
  String? error;
  @override
  void initState() {
    super.initState();
    final copy = jsonDecode(jsonEncode(widget.initial)) as Map;
    groups = (copy['groups'] as List? ?? []).cast<Map<String, dynamic>>();
    rules = (copy['rules'] as List? ?? []).cast<Map<String, dynamic>>();
    for (final group in groups) {
      for (final value in group['values'] as List) {
        value.putIfAbsent('default_quantity', () => 0);
        value.putIfAbsent('recipe_additions', () => <Map<String, dynamic>>[]);
      }
    }
    _loadIngredientNames();
  }

  Future<void> _loadIngredientNames() async {
    final ids = {
      for (final g in groups)
        for (final v in g['values'] as List)
          for (final r in v['recipe_additions'] as List? ?? [])
            r['ingredient_id'] as String,
    };
    if (ids.isEmpty || widget.storeId == null) return;
    try {
      final rows = await supabase
          .from('inventory_items')
          .select('id,name')
          .eq('restaurant_id', widget.storeId!)
          .inFilter('id', ids.toList());
      if (!mounted) return;
      setState(() {
        for (final row in rows) {
          ingredientNames[row['id'] as String] = row['name'] as String;
        }
      });
    } catch (_) {
      if (mounted) {
        setState(
          () => error = text(
            '원료 이름을 불러오지 못했습니다.',
            'Không tải được tên nguyên liệu.',
            'Unable to load ingredient names.',
          ),
        );
      }
    }
  }

  String text(String ko, String vi, String en) =>
      switch (Localizations.localeOf(context).languageCode) {
        'ko' => ko,
        'vi' => vi,
        _ => en,
      };
  String label(Map<String, dynamic> v) =>
      (v['name_${Localizations.localeOf(context).languageCode}'] as String?) ??
      v['name_en'] as String? ??
      '';
  Widget names(Map<String, dynamic> v) => Column(
    children: [
      for (final language in ['ko', 'vi', 'en'])
        TextFormField(
          key: ValueKey('${v['id']}_$language'),
          initialValue: v['name_$language'] as String? ?? '',
          maxLength: 80,
          decoration: InputDecoration(
            labelText: '${text('이름', 'Tên', 'Name')} · $language',
          ),
          validator: (s) => (s?.trim().isEmpty ?? true)
              ? text('필수', 'Bắt buộc', 'Required')
              : null,
          onChanged: (s) => v['name_$language'] = s.trim(),
        ),
    ],
  );
  Widget number(
    Map<String, dynamic> obj,
    String key,
    String title, {
    int max = 8,
  }) => DropdownButtonFormField<int>(
    key: ValueKey('${obj['id']}_$key'),
    initialValue: (obj[key] as num? ?? 0).toInt(),
    decoration: InputDecoration(labelText: title),
    items: [
      for (var n = key == 'max' ? 1 : 0; n <= max; n++)
        DropdownMenuItem(value: n, child: Text('$n')),
    ],
    onChanged: (n) => setState(() => obj[key] = n),
  );
  Future<void> addRecipe(Map<String, dynamic> value) async {
    if (widget.storeId == null) return;
    final ingredient = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (_) => _IngredientDialog(storeId: widget.storeId!),
    );
    if (!mounted || ingredient == null) return;
    setState(() {
      ingredientNames[ingredient['id'] as String] =
          ingredient['name'] as String;
      (value['recipe_additions'] as List).add({
        'ingredient_id': ingredient['id'],
        'quantity_g': 0,
      });
    });
  }

  void save() {
    if (!form.currentState!.validate()) return;
    final ids = {
      for (final g in groups)
        for (final v in g['values'] as List) v['id'],
    };
    if (groups.any(
          (g) =>
              (g['min'] as int) > (g['max'] as int) ||
              (g['channels'] as List).isEmpty ||
              (g['values'] as List).isEmpty ||
              (g['values'] as List).fold<int>(
                    0,
                    (sum, v) => sum + (v['default_quantity'] as int? ?? 0),
                  ) >
                  (g['max'] as int),
        ) ||
        rules.any(
          (r) =>
              r['from'] == r['to'] ||
              !ids.contains(r['from']) ||
              !ids.contains(r['to']),
        )) {
      setState(
        () => error = text(
          '선택 범위·기본값·조건을 확인해 주세요.',
          'Kiểm tra giới hạn, mặc định và điều kiện.',
          'Check limits, defaults and rules.',
        ),
      );
      return;
    }
    final definition = groups.isEmpty
        ? <String, dynamic>{}
        : {'schema_version': 1, 'groups': groups, 'rules': rules};
    if (utf8.encode(jsonEncode(definition)).length > 15000 || ids.length > 64) {
      setState(
        () => error = text(
          '선택값은 전체 64개까지 등록할 수 있습니다. 내용을 줄여 주세요.',
          'Tối đa 64 lựa chọn. Hãy rút gọn nội dung.',
          'Up to 64 values. Reduce the definition size.',
        ),
      );
      return;
    }
    Navigator.pop(context, definition);
  }

  @override
  Widget build(BuildContext context) {
    final values = [
      for (final g in groups)
        ...(g['values'] as List).cast<Map<String, dynamic>>(),
    ];
    return AlertDialog(
      key: const Key('menu_choice_editor'),
      title: Text(text('고객 선택 옵션', 'Tùy chọn của khách', 'Customer choices')),
      content: SizedBox(
        width: 600,
        child: Form(
          key: form,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (error != null)
                  Text(
                    error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
                for (final g in groups)
                  Card(
                    key: ValueKey(g['id']),
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          Row(
                            children: [
                              Expanded(child: Text(label(g))),
                              IconButton(
                                tooltip: text(
                                  '선택군 삭제',
                                  'Xóa nhóm',
                                  'Remove group',
                                ),
                                onPressed: () => setState(() {
                                  final removed = {
                                    (g['values'] as List).map((v) => v['id']),
                                  }.expand((x) => x).toSet();
                                  rules.removeWhere(
                                    (r) =>
                                        removed.contains(r['from']) ||
                                        removed.contains(r['to']),
                                  );
                                  groups.remove(g);
                                }),
                                icon: const Icon(Icons.delete_outline),
                              ),
                            ],
                          ),
                          names(g),
                          Row(
                            children: [
                              Expanded(
                                child: number(
                                  g,
                                  'min',
                                  text(
                                    '최소 선택 수',
                                    'Số lượng tối thiểu',
                                    'Minimum selections',
                                  ),
                                ),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: number(
                                  g,
                                  'max',
                                  text(
                                    '최대 선택 수',
                                    'Số lượng tối đa',
                                    'Maximum selections',
                                  ),
                                ),
                              ),
                            ],
                          ),
                          SwitchListTile(
                            title: Text(
                              text(
                                '같은 선택값 여러 개 허용',
                                'Cho phép lặp lựa chọn',
                                'Allow repeated values',
                              ),
                            ),
                            value: g['repeat'] == true,
                            onChanged: (v) => setState(() => g['repeat'] = v),
                          ),
                          Wrap(
                            spacing: 8,
                            children: [
                              for (final channel in ['pos', 'qr', 'direct'])
                                FilterChip(
                                  label: Text(
                                    channel == 'direct'
                                        ? text(
                                            '직접 주문',
                                            'Đặt trực tiếp',
                                            'Direct order',
                                          )
                                        : channel.toUpperCase(),
                                  ),
                                  selected: (g['channels'] as List).contains(
                                    channel,
                                  ),
                                  onSelected: (v) => setState(
                                    () => v
                                        ? (g['channels'] as List).add(channel)
                                        : (g['channels'] as List).remove(
                                            channel,
                                          ),
                                  ),
                                ),
                            ],
                          ),
                          for (final v
                              in (g['values'] as List)
                                  .cast<Map<String, dynamic>>())
                            ExpansionTile(
                              key: ValueKey(v['id']),
                              title: Text(
                                label(v).isEmpty
                                    ? text('새 선택값', 'Lựa chọn mới', 'New value')
                                    : label(v),
                              ),
                              children: [
                                names(v),
                                TextFormField(
                                  initialValue: '${v['price_delta']}',
                                  decoration: InputDecoration(
                                    labelText: text(
                                      '추가 가격 (VND)',
                                      'Giá thêm (VND)',
                                      'Additional price (VND)',
                                    ),
                                  ),
                                  keyboardType: TextInputType.number,
                                  validator: (s) =>
                                      !RegExp(
                                        r'^\d{1,9}(\.\d{1,2})?$',
                                      ).hasMatch(s ?? '')
                                      ? text(
                                          '0 이상의 가격',
                                          'Giá không âm',
                                          'Nonnegative price',
                                        )
                                      : null,
                                  onChanged: (s) =>
                                      v['price_delta'] = num.tryParse(s) ?? -1,
                                ),
                                SwitchListTile(
                                  title: Text(
                                    text('선택 가능', 'Có sẵn', 'Available'),
                                  ),
                                  value: v['available'] == true,
                                  onChanged: (b) =>
                                      setState(() => v['available'] = b),
                                ),
                                number(
                                  v,
                                  'default_quantity',
                                  text(
                                    '기본 선택 수',
                                    'Số lượng mặc định',
                                    'Default quantity',
                                  ),
                                ),
                                for (final r
                                    in v['recipe_additions'] as List? ?? [])
                                  Row(
                                    children: [
                                      Expanded(
                                        child: Text(
                                          ingredientNames[r['ingredient_id']] ??
                                              text(
                                                '등록 원료',
                                                'Nguyên liệu đã đăng ký',
                                                'Registered ingredient',
                                              ),
                                        ),
                                      ),
                                      SizedBox(
                                        width: 130,
                                        child: TextFormField(
                                          key: ValueKey(r),
                                          initialValue: '${r['quantity_g']}',
                                          decoration: const InputDecoration(
                                            labelText: 'g',
                                          ),
                                          keyboardType: TextInputType.number,
                                          validator: (s) =>
                                              !RegExp(
                                                    r'^\d{1,6}(\.\d{1,3})?$',
                                                  ).hasMatch(s ?? '') ||
                                                  (num.tryParse(s ?? '') ??
                                                          0) <=
                                                      0
                                              ? text(
                                                  '0 초과',
                                                  'Lớn hơn 0',
                                                  'Positive quantity',
                                                )
                                              : null,
                                          onChanged: (s) => r['quantity_g'] =
                                              num.tryParse(s) ?? 0,
                                        ),
                                      ),
                                      IconButton(
                                        onPressed: () => setState(
                                          () => (v['recipe_additions'] as List)
                                              .remove(r),
                                        ),
                                        icon: const Icon(Icons.close),
                                      ),
                                    ],
                                  ),
                                TextButton.icon(
                                  onPressed:
                                      widget.storeId == null ||
                                          (v['recipe_additions'] as List? ?? [])
                                                  .length >=
                                              8
                                      ? null
                                      : () => addRecipe(v),
                                  icon: const Icon(Icons.add),
                                  label: Text(
                                    text(
                                      '추가 원료',
                                      'Thêm nguyên liệu',
                                      'Add ingredient',
                                    ),
                                  ),
                                ),
                                TextButton(
                                  onPressed: () => setState(() {
                                    rules.removeWhere(
                                      (r) =>
                                          r['from'] == v['id'] ||
                                          r['to'] == v['id'],
                                    );
                                    (g['values'] as List).remove(v);
                                  }),
                                  child: Text(
                                    text(
                                      '선택값 삭제',
                                      'Xóa lựa chọn',
                                      'Remove value',
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          TextButton.icon(
                            onPressed:
                                values.length >= 64 ||
                                    (g['values'] as List).length >= 32
                                ? null
                                : () => setState(
                                    () => (g['values'] as List).add({
                                      'id': const Uuid().v4(),
                                      'name_ko': '',
                                      'name_vi': '',
                                      'name_en': '',
                                      'price_delta': 0,
                                      'available': true,
                                      'default_quantity': 0,
                                      'recipe_additions':
                                          <Map<String, dynamic>>[],
                                    }),
                                  ),
                            icon: const Icon(Icons.add),
                            label: Text(
                              text('선택값 추가', 'Thêm lựa chọn', 'Add value'),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                TextButton.icon(
                  key: const Key('menu_choice_add_group'),
                  onPressed: groups.length >= 8
                      ? null
                      : () => setState(
                          () => groups.add({
                            'id': const Uuid().v4(),
                            'name_ko': '',
                            'name_vi': '',
                            'name_en': '',
                            'min': 1,
                            'max': 1,
                            'repeat': false,
                            'channels': ['pos', 'qr', 'direct'],
                            'values': <Map<String, dynamic>>[],
                          }),
                        ),
                  icon: const Icon(Icons.add),
                  label: Text(text('선택군 추가', 'Thêm nhóm', 'Add group')),
                ),
                for (final r in rules)
                  Row(
                    children: [
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: r['from'] as String?,
                          items: [
                            for (final v in values)
                              DropdownMenuItem(
                                value: v['id'] as String,
                                child: Text(label(v)),
                              ),
                          ],
                          onChanged: (v) => setState(() => r['from'] = v),
                        ),
                      ),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: r['kind'] as String,
                          items: [
                            DropdownMenuItem(
                              value: 'requires',
                              child: Text(
                                text('함께 필수', 'Yêu cầu kèm', 'Requires'),
                              ),
                            ),
                            DropdownMenuItem(
                              value: 'excludes',
                              child: Text(
                                text('함께 불가', 'Không kết hợp', 'Excludes'),
                              ),
                            ),
                          ],
                          onChanged: (v) => setState(() => r['kind'] = v),
                        ),
                      ),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: r['to'] as String?,
                          items: [
                            for (final v in values)
                              DropdownMenuItem(
                                value: v['id'] as String,
                                child: Text(label(v)),
                              ),
                          ],
                          onChanged: (v) => setState(() => r['to'] = v),
                        ),
                      ),
                      IconButton(
                        onPressed: () => setState(() => rules.remove(r)),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                TextButton(
                  onPressed: values.length < 2 || rules.length >= 32
                      ? null
                      : () => setState(
                          () => rules.add({
                            'kind': 'requires',
                            'from': values[0]['id'],
                            'to': values[1]['id'],
                          }),
                        ),
                  child: Text(
                    text('선택 조건 추가', 'Thêm điều kiện', 'Add selection rule'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(text('취소', 'Hủy', 'Cancel')),
        ),
        FilledButton(
          key: const Key('menu_choice_save'),
          onPressed: save,
          child: Text(text('메뉴에 반영', 'Áp dụng cho món', 'Apply to menu')),
        ),
      ],
    );
  }
}

class _IngredientDialog extends StatefulWidget {
  const _IngredientDialog({required this.storeId});
  final String storeId;
  @override
  State<_IngredientDialog> createState() => _IngredientDialogState();
}

class _IngredientDialogState extends State<_IngredientDialog> {
  List<Map<String, dynamic>> rows = [];
  bool loading = false;
  String? error;
  int revision = 0;
  Future<void> search(String term) async {
    final request = ++revision;
    setState(() => loading = true);
    try {
      final escaped = term
          .trim()
          .replaceAll('\\', '\\\\')
          .replaceAll('%', '\\%')
          .replaceAll('_', '\\_');
      final result = await supabase
          .from('inventory_items')
          .select('id,name')
          .eq('restaurant_id', widget.storeId)
          .ilike('name', '%$escaped%')
          .order('name')
          .limit(30);
      if (!mounted || request != revision) return;
      setState(() {
        rows = result;
        error = null;
      });
    } catch (_) {
      if (mounted && request == revision) {
        setState(() => error = 'Unable to load ingredients');
      }
    } finally {
      if (mounted && request == revision) setState(() => loading = false);
    }
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(switch (Localizations.localeOf(context).languageCode) {
      'ko' => '원료',
      'vi' => 'Nguyên liệu',
      _ => 'Ingredient',
    }),
    content: SizedBox(
      width: 480,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            onSubmitted: search,
            decoration: InputDecoration(
              labelText: switch (Localizations.localeOf(context).languageCode) {
                'ko' => '검색',
                'vi' => 'Tìm kiếm',
                _ => 'Search',
              },
            ),
          ),
          if (loading) const LinearProgressIndicator(),
          if (error != null)
            Text(switch (Localizations.localeOf(context).languageCode) {
              'ko' => '원료를 불러오지 못했습니다.',
              'vi' => 'Không thể tải nguyên liệu.',
              _ => 'Could not load ingredients.',
            }),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [
                for (final row in rows)
                  ListTile(
                    title: Text(row['name'] as String),
                    onTap: () => Navigator.pop(context, row),
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );
}
