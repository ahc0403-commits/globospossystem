import 'direct_order_models.dart';

String normalizeDirectOrderMenuSearch(String value) {
  var result = value.toLowerCase().replaceAll(RegExp(r'[\u0300-\u036f]'), '');
  const groups = {
    'a': 'àáạảãâầấậẩẫăằắặẳẵ',
    'e': 'èéẹẻẽêềếệểễ',
    'i': 'ìíịỉĩ',
    'o': 'òóọỏõôồốộổỗơờớợởỡ',
    'u': 'ùúụủũưừứựửữ',
    'y': 'ỳýỵỷỹ',
    'd': 'đ',
  };
  for (final group in groups.entries) {
    for (final rune in group.value.runes) {
      result = result.replaceAll(String.fromCharCode(rune), group.key);
    }
  }
  return result.trim().replaceAll(RegExp(r'\s+'), ' ');
}

bool directOrderMenuMatches(DirectOrderMenuItem item, String query) {
  if (query.trim().isEmpty) return true;
  final words = normalizeDirectOrderMenuSearch(query).split(' ');
  final names = normalizeDirectOrderMenuSearch(
    '${item.nameKo} ${item.nameVi} ${item.nameEn}',
  );
  return words.every(names.contains);
}
