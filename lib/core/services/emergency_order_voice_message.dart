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

/// Builds the Vietnamese-only announcement used by paperless KDS stations.
///
/// Table digits are spoken individually so operational table codes such as
/// 1101 cannot be mistaken for a cardinal number.
String vietnameseNewOrderMessage(String tableNumber) {
  final spokenDigits = RegExp(r'\d')
      .allMatches(tableNumber)
      .map((match) => _vietnameseDigits[match.group(0)]!)
      .join(' ');
  if (spokenDigits.isEmpty) return 'Có đơn hàng mới.';
  return 'Bàn $spokenDigits, có đơn hàng mới.';
}
