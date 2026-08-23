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

/// Announces a leftover-food packaging task only when it becomes actionable
/// at the current station.
String vietnameseLeftoverPackagingMessage(String tableNumber, String status) {
  final spokenDigits = RegExp(r'\d')
      .allMatches(tableNumber)
      .map((match) => _vietnameseDigits[match.group(0)]!)
      .join(' ');
  final table = spokenDigits.isEmpty ? '' : 'Bàn $spokenDigits, ';
  return switch (status) {
    'awaiting_floor_pickup' => '${table}có yêu cầu đóng gói đồ ăn thừa.',
    'awaiting_tray_to_kitchen' => '${table}có yêu cầu đóng gói chuyển đến bếp.',
    'awaiting_kitchen_packaging' => '${table}cần đóng gói đồ ăn thừa.',
    'awaiting_tray_return' =>
      '$table\u0111ồ ăn đã đóng gói cần chuyển về tầng.',
    'awaiting_floor_delivery' =>
      '$table\u0111ồ ăn đã đóng gói cần giao cho khách.',
    _ => '${table}có yêu cầu đóng gói.',
  };
}
