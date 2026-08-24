const _vietnameseDigits = <String, String>{
  '0': 'không',
  '1': 'một',
  '2': 'hai',
  '3': 'ba',
  '4': 'bốn',
  '5': 'năm',
  '6': 'sáu',
  '7': 'bảy',
  '8': 'tám',
  '9': 'chín',
};

/// Builds the kitchen announcement for items added to an existing order.
String vietnameseAdditionalOrderMessage(String tableNumber) {
  final spokenDigits = RegExp(r'\d')
      .allMatches(tableNumber)
      .map((match) => _vietnameseDigits[match.group(0)]!)
      .join(' ');
  if (spokenDigits.isEmpty) return 'Có món gọi thêm.';
  return 'Bàn $spokenDigits, có món gọi thêm.';
}
