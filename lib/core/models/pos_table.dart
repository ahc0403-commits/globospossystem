class PosTable {
  const PosTable({
    required this.id,
    required this.storeId,
    required this.tableNumber,
    required this.seatCount,
    required this.status,
  });

  final String id;
  final String storeId;
  final String tableNumber;
  final int? seatCount;
  final String status;

  bool get isOccupied => status.toLowerCase() == 'occupied';

  factory PosTable.fromJson(Map<String, dynamic> json) {
    final seatRaw = json['seat_count'];
    final occupied = json['is_occupied'];

    String resolvedStatus;
    if (json['status'] != null) {
      resolvedStatus = json['status'].toString();
    } else if (occupied is bool) {
      resolvedStatus = occupied ? 'occupied' : 'available';
    } else {
      resolvedStatus = 'available';
    }

    return PosTable(
      id: json['id'].toString(),
      storeId: json['restaurant_id']?.toString() ?? '',
      tableNumber: json['table_number']?.toString() ?? '-',
      seatCount: switch (seatRaw) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value),
        _ => null,
      },
      status: resolvedStatus.toLowerCase(),
    );
  }
}
