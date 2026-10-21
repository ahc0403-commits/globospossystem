import 'package:flutter/material.dart';

/// One registered dish can own both S/L prices. The chosen size is retained
/// independently in carts and immutable order snapshots.
class MenuOptions {
  const MenuOptions({
    this.portion = '',
    this.spice = 'unknown',
    this.choice = '',
    this.sizePrices = const {},
    this.mealChoices = false,
  });
  final bool mealChoices;
  final String portion;
  final String spice;
  final String choice;
  final Map<String, double> sizePrices;
  bool get hasSizes => sizePrices.isNotEmpty;
  bool get validSizePrices =>
      !hasSizes ||
      (sizePrices.length == 2 &&
          (sizePrices['S'] ?? 0) > 0 &&
          (sizePrices['L'] ?? 0) > 0);
  MenuOptions copyWith({
    String? portion,
    String? spice,
    String? choice,
    Map<String, double>? sizePrices,
    bool? mealChoices,
  }) => MenuOptions(
    mealChoices: mealChoices ?? this.mealChoices,
    portion: portion ?? this.portion,
    spice: spice ?? this.spice,
    choice: choice ?? this.choice,
    sizePrices: sizePrices ?? this.sizePrices,
  );

  factory MenuOptions.fromJson(Map<String, dynamic> json) => MenuOptions(
    mealChoices: json['meal_choices'] == true,
    portion: json['portion_code']?.toString() ?? '',
    spice: json['spice_level']?.toString() ?? 'unknown',
    choice: json['spice_choice']?.toString() ?? '',
    sizePrices: json['size_prices'] is Map
        ? (json['size_prices'] as Map).map(
            (key, value) => MapEntry(key.toString(), (value as num).toDouble()),
          )
        : const {},
  );

  Map<String, dynamic> toJson() => {
    'meal_choices': mealChoices,
    'portion_code': hasSizes ? 'S' : portion,
    'size_prices': sizePrices,
    'spice_level': spice,
    'spice_choice': choice.trim(),
  };

  @override
  bool operator ==(Object other) =>
      other is MenuOptions &&
      mealChoices == other.mealChoices &&
      portion == other.portion &&
      spice == other.spice &&
      choice == other.choice &&
      sizePrices['S'] == other.sizePrices['S'] &&
      sizePrices['L'] == other.sizePrices['L'];
  @override
  int get hashCode => Object.hash(
    portion,
    spice,
    choice,
    sizePrices['S'],
    sizePrices['L'],
    mealChoices,
  );
}

String menuBaseName(Map<String, dynamic> item, String key) {
  final bases = item['option_base_names'];
  if (bases is Map && bases[key] != null) return bases[key].toString();
  final name = item[key]?.toString() ?? '';
  if (name.trim().isNotEmpty || key == 'paperless_name_vi') return name;
  return item['name']?.toString() ?? '';
}

class MenuOptionsEditor extends StatelessWidget {
  const MenuOptionsEditor({
    super.key,
    required this.value,
    required this.onChanged,
    this.allowSizes = false,
  });
  final MenuOptions value;
  final ValueChanged<MenuOptions> onChanged;
  final bool allowSizes;

  @override
  Widget build(BuildContext context) {
    final language = Localizations.localeOf(context).languageCode;
    String text(String ko, String vi, String en) => switch (language) {
      'vi' => vi,
      'en' => en,
      _ => ko,
    };
    return ExpansionTile(
      key: const Key('admin_menu_options_expansion'),
      title: Text(
        allowSizes
            ? text(
                '사이즈별 가격·맵기',
                'Giá theo cỡ · Độ cay',
                'Size prices & spiciness',
              )
            : text('양·맵기', 'Khẩu phần · Độ cay', 'Portion & spiciness'),
      ),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SwitchListTile(
              key: const Key('admin_menu_meal_choices'),
              title: Text(
                text(
                  '면·밥 필수 선택',
                  'Bắt buộc chọn mì/cơm',
                  'Require noodles or rice',
                ),
              ),
              subtitle: Text(
                text(
                  '고객이 면 또는 밥을 선택합니다. 가격은 등록된 메뉴 가격을 사용합니다.',
                  'Khách chọn mì hoặc cơm với giá món đã đăng ký.',
                  'Customers choose noodles or rice at the registered menu price.',
                ),
              ),
              value: value.mealChoices,
              onChanged: (enabled) =>
                  onChanged(value.copyWith(mealChoices: enabled)),
            ),
            if (allowSizes) ...[
              SwitchListTile(
                key: const Key('admin_menu_has_sizes'),
                title: Text(text('사이즈별 가격', 'Giá theo cỡ', 'Prices by size')),
                value: value.hasSizes,
                onChanged: (enabled) => onChanged(
                  value.copyWith(
                    portion: '',
                    sizePrices: enabled ? {'S': 0, 'L': 0} : {},
                  ),
                ),
              ),
              if (value.hasSizes)
                for (final size in ['S', 'L'])
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: TextFormField(
                      key: Key('admin_menu_size_price_$size'),
                      initialValue: (value.sizePrices[size] ?? 0) <= 0
                          ? ''
                          : value.sizePrices[size]!.toStringAsFixed(0),
                      keyboardType: TextInputType.number,
                      decoration: InputDecoration(labelText: '$size · VND'),
                      onChanged: (text) => onChanged(
                        value.copyWith(
                          sizePrices: {
                            ...value.sizePrices,
                            size:
                                double.tryParse(
                                  text.replaceAll(',', '').trim(),
                                ) ??
                                0,
                          },
                        ),
                      ),
                    ),
                  ),
            ] else
              DropdownButtonFormField<String>(
                key: const Key('admin_menu_portion'),
                initialValue: value.portion,
                decoration: InputDecoration(
                  labelText: text('양', 'Khẩu phần', 'Portion'),
                ),
                items: [
                  DropdownMenuItem(
                    value: '',
                    child: Text(text('단일 규격', 'Một cỡ', 'Single size')),
                  ),
                  const DropdownMenuItem(value: 'S', child: Text('S')),
                  const DropdownMenuItem(value: 'L', child: Text('L')),
                ],
                onChanged: (v) => onChanged(
                  MenuOptions(
                    mealChoices: value.mealChoices,
                    portion: v ?? '',
                    spice: value.spice,
                    choice: value.choice,
                    sizePrices: value.sizePrices,
                  ),
                ),
              ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              key: const Key('admin_menu_spice'),
              initialValue: value.spice,
              decoration: InputDecoration(
                labelText: text('기본 맵기', 'Độ cay', 'Base spiciness'),
              ),
              items: [
                DropdownMenuItem(
                  value: 'unknown',
                  child: Text(text('미확인', 'Chưa xác nhận', 'Unconfirmed')),
                ),
                DropdownMenuItem(
                  value: 'not_spicy',
                  child: Text(text('안 매움', 'Không cay', 'Not spicy')),
                ),
                DropdownMenuItem(
                  value: 'spicy',
                  child: Text(text('🌶 매운 메뉴', '🌶 Món cay', '🌶 Spicy dish')),
                ),
              ],
              onChanged: (v) => onChanged(
                MenuOptions(
                  mealChoices: value.mealChoices,
                  portion: value.portion,
                  spice: v ?? 'unknown',
                  choice: value.choice,
                  sizePrices: value.sizePrices,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextFormField(
              key: const Key('admin_menu_spice_choice'),
              initialValue: value.choice,
              maxLength: 60,
              decoration: InputDecoration(
                labelText: text(
                  '조절 가능한 메뉴의 맵기 선택명 (선택)',
                  'Tên lựa chọn độ cay (nếu có)',
                  'Registered spice choice (optional)',
                ),
              ),
              onChanged: (v) => onChanged(
                MenuOptions(
                  mealChoices: value.mealChoices,
                  portion: value.portion,
                  spice: value.spice,
                  choice: v,
                  sizePrices: value.sizePrices,
                ),
              ),
            ),
            Text(
              text(
                allowSizes
                    ? '메뉴는 한 번만 등록합니다. S와 L 가격을 입력하면 고객이 메뉴를 눌러 사이즈를 선택합니다.'
                    : '등록된 규격과 실제 판매 가격을 입력하세요.',
                allowSizes
                    ? 'Đăng ký một món với giá S và L. Khách chọn cỡ sau khi chọn món.'
                    : 'Nhập khẩu phần và giá bán thực tế.',
                allowSizes
                    ? 'Register one dish with S and L prices. Customers tap the dish and choose a size.'
                    : 'Enter the registered portion and its actual price.',
              ),
            ),
          ],
        ),
      ],
    );
  }
}
