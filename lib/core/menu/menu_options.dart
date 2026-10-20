import 'package:flutter/material.dart';

/// One registered sellable choice has one stable menu ID and explicit price.
/// Distinct sizes/spice choices therefore remain distinct in every existing cart.
class MenuOptions {
  const MenuOptions({
    this.portion = '',
    this.spice = 'unknown',
    this.choice = '',
  });
  final String portion;
  final String spice;
  final String choice;

  factory MenuOptions.fromJson(Map<String, dynamic> json) => MenuOptions(
    portion: json['portion_code']?.toString() ?? '',
    spice: json['spice_level']?.toString() ?? 'unknown',
    choice: json['spice_choice']?.toString() ?? '',
  );

  Map<String, dynamic> toJson() => {
    'portion_code': portion,
    'spice_level': spice,
    'spice_choice': choice.trim(),
  };

  @override
  bool operator ==(Object other) =>
      other is MenuOptions &&
      portion == other.portion &&
      spice == other.spice &&
      choice == other.choice;
  @override
  int get hashCode => Object.hash(portion, spice, choice);
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
  });
  final MenuOptions value;
  final ValueChanged<MenuOptions> onChanged;

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
      title: Text(text('양·맵기', 'Khẩu phần · Độ cay', 'Portion & spiciness')),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
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
                  portion: v ?? '',
                  spice: value.spice,
                  choice: value.choice,
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
                  portion: value.portion,
                  spice: v ?? 'unknown',
                  choice: value.choice,
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
                  portion: value.portion,
                  spice: value.spice,
                  choice: v,
                ),
              ),
            ),
            Text(
              text(
                'S와 L은 각각 메뉴로 등록하고 실제 판매 가격을 입력하세요. 조절 가능한 맵기도 허용하는 선택마다 등록하세요. 주문자는 등록된 선택만 주문할 수 있습니다.',
                'Đăng ký riêng S và L với giá bán thực tế. Nếu cho phép đổi độ cay, đăng ký từng lựa chọn được phép.',
                'Register S and L separately with their actual prices. For adjustable dishes, register each permitted spice choice.',
              ),
            ),
          ],
        ),
      ],
    );
  }
}
