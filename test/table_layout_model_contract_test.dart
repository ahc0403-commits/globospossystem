import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/models/pos_table.dart';

void main() {
  test('PosTable parses normalized floor layout fields with defaults', () {
    final table = PosTable.fromJson({
      'id': 'table-1',
      'restaurant_id': 'store-1',
      'table_number': 'A1',
      'seat_count': 4,
      'status': 'available',
      'layout_x': '0.2500',
      'layout_y': 0.5,
      'layout_w': '0.1800',
      'layout_h': 0.14,
      'layout_rotation': '15',
      'layout_shape': 'round',
      'layout_sort_order': '7',
    });

    expect(table.layoutX, 0.25);
    expect(table.layoutY, 0.5);
    expect(table.layoutW, 0.18);
    expect(table.layoutH, 0.14);
    expect(table.layoutRotation, 15);
    expect(table.layoutShape, PosTableShape.round);
    expect(table.layoutSortOrder, 7);
  });

  test('PosTable falls back to visible layout defaults', () {
    final table = PosTable.fromJson({
      'id': 'table-1',
      'restaurant_id': 'store-1',
      'table_number': 'A1',
    });

    expect(table.layoutX, 0);
    expect(table.layoutY, 0);
    expect(table.layoutW, 0.18);
    expect(table.layoutH, 0.14);
    expect(table.layoutRotation, 0);
    expect(table.layoutShape, PosTableShape.rectangle);
    expect(table.layoutSortOrder, 0);
  });
}
