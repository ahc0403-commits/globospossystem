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
  final spokenDigits = _spokenTableDigits(tableNumber);
  if (spokenDigits.isEmpty) return 'Có đơn hàng mới.';
  return 'Bàn $spokenDigits, có đơn hàng mới.';
}

/// Builds the floor-station announcement for newly ordered beverages.
String vietnameseFloorDirectBeverageMessage(int itemCount) {
  final count = itemCount < 0 ? 0 : itemCount;
  return 'Có đồ uống mới. Tổng cộng ${_spokenVietnameseCount(count)} món.';
}

/// Builds the handoff announcement played at the receiving station.
String vietnameseHandoffMessage(
  String tableNumber,
  int itemCount,
  String stationType,
) {
  final spokenDigits = _spokenTableDigits(tableNumber);
  final count = itemCount < 0 ? 0 : itemCount;
  final spokenCount = _vietnameseDigits['$count'] ?? '$count';
  final completion = '$spokenCount món đã hoàn thành.';
  if (spokenDigits.isEmpty) return completion;
  return 'Bàn $spokenDigits, $completion';
}

String _spokenTableDigits(String tableNumber) => RegExp(r'\d')
    .allMatches(tableNumber)
    .map((match) => _vietnameseDigits[match.group(0)]!)
    .join(' ');

String _spokenVietnameseCount(int count) {
  if (count < 10) return _vietnameseDigits['$count']!;
  if (count >= 1000) return '$count';

  final parts = <String>[];
  final hundreds = count ~/ 100;
  final remainder = count % 100;
  if (hundreds > 0) {
    parts
      ..add(_vietnameseDigits['$hundreds']!)
      ..add('trăm');
    if (remainder > 0 && remainder < 10) parts.add('lẻ');
  }
  if (remainder >= 10) {
    final tens = remainder ~/ 10;
    parts.add(tens == 1 ? 'mười' : '${_vietnameseDigits['$tens']} mươi');
  }
  final units = remainder % 10;
  if (units > 0) {
    final tens = remainder ~/ 10;
    parts.add(switch (units) {
      1 when tens > 1 => 'mốt',
      4 when tens > 1 => 'tư',
      5 when tens > 0 => 'lăm',
      _ => _vietnameseDigits['$units']!,
    });
  }
  return parts.join(' ');
}
