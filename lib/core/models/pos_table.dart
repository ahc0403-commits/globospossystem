import 'dart:ui';

enum PosTableShape { rectangle, round }

class PosTable {
  const PosTable({
    required this.id,
    required this.storeId,
    required this.tableNumber,
    required this.seatCount,
    required this.status,
    this.floorLabel = '1F',
    this.layoutX = 0,
    this.layoutY = 0,
    this.layoutW = 0.18,
    this.layoutH = 0.14,
    this.layoutRotation = 0,
    this.layoutShape = PosTableShape.rectangle,
    this.layoutSortOrder = 0,
  });

  final String id;
  final String storeId;
  final String tableNumber;
  final int? seatCount;
  final String status;
  final String floorLabel;
  final double layoutX;
  final double layoutY;
  final double layoutW;
  final double layoutH;
  final int layoutRotation;
  final PosTableShape layoutShape;
  final int layoutSortOrder;

  bool get isOccupied => status.toLowerCase() == 'occupied';
  bool get isReserved => status.toLowerCase() == 'reserved';
  bool get isAvailable => status.toLowerCase() == 'available';

  Rect get layoutRect => Rect.fromLTWH(layoutX, layoutY, layoutW, layoutH);

  PosTable copyWithStatus(String status) {
    return PosTable(
      id: id,
      storeId: storeId,
      tableNumber: tableNumber,
      seatCount: seatCount,
      status: status.toLowerCase(),
      floorLabel: floorLabel,
      layoutX: layoutX,
      layoutY: layoutY,
      layoutW: layoutW,
      layoutH: layoutH,
      layoutRotation: layoutRotation,
      layoutShape: layoutShape,
      layoutSortOrder: layoutSortOrder,
    );
  }

  static int normalizeLayoutRotation(int value) {
    var normalized = value % 360;
    if (normalized > 180) {
      normalized -= 360;
    }
    return normalized;
  }

  PosTable copyWithLayout(
    Rect rect, {
    int? layoutRotation,
    PosTableShape? layoutShape,
    int? layoutSortOrder,
  }) {
    return PosTable(
      id: id,
      storeId: storeId,
      tableNumber: tableNumber,
      seatCount: seatCount,
      status: status,
      floorLabel: floorLabel,
      layoutX: rect.left,
      layoutY: rect.top,
      layoutW: rect.width,
      layoutH: rect.height,
      layoutRotation: normalizeLayoutRotation(
        layoutRotation ?? this.layoutRotation,
      ),
      layoutShape: layoutShape ?? this.layoutShape,
      layoutSortOrder: layoutSortOrder ?? this.layoutSortOrder,
    );
  }

  static double _doubleValue(dynamic value, double fallback) {
    return switch (value) {
      num raw => raw.toDouble(),
      String raw => double.tryParse(raw) ?? fallback,
      _ => fallback,
    };
  }

  static int _intValue(dynamic value, int fallback) {
    return switch (value) {
      int raw => raw,
      num raw => raw.toInt(),
      String raw => int.tryParse(raw) ?? fallback,
      _ => fallback,
    };
  }

  static PosTableShape _shapeValue(dynamic value) {
    return value?.toString().toLowerCase() == 'round'
        ? PosTableShape.round
        : PosTableShape.rectangle;
  }

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
      floorLabel: json['floor_label']?.toString() ?? '1F',
      layoutX: _doubleValue(json['layout_x'], 0),
      layoutY: _doubleValue(json['layout_y'], 0),
      layoutW: _doubleValue(json['layout_w'], 0.18),
      layoutH: _doubleValue(json['layout_h'], 0.14),
      layoutRotation: normalizeLayoutRotation(
        _intValue(json['layout_rotation'], 0),
      ),
      layoutShape: _shapeValue(json['layout_shape']),
      layoutSortOrder: _intValue(json['layout_sort_order'], 0),
    );
  }
}
