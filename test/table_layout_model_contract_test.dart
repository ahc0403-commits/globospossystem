import 'dart:ui';

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

  test('PosTable layout copy preserves and overrides edit metadata', () {
    final table = PosTable.fromJson({
      'id': 'table-1',
      'restaurant_id': 'store-1',
      'table_number': 'T01',
      'seat_count': 4,
      'status': 'available',
      'layout_x': 0.1,
      'layout_y': 0.2,
      'layout_w': 0.18,
      'layout_h': 0.14,
      'layout_rotation': 15,
    });

    final moved = table.copyWithLayout(
      const Rect.fromLTWH(0.2, 0.3, 0.24, 0.18),
      layoutRotation: 45,
    );

    expect(moved.layoutX, 0.2);
    expect(moved.layoutY, 0.3);
    expect(moved.layoutW, 0.24);
    expect(moved.layoutH, 0.18);
    expect(moved.layoutRotation, 45);
  });

  test('PosTable normalizes layout rotation to the database constraint range', () {
    expect(PosTable.normalizeLayoutRotation(0), 0);
    expect(PosTable.normalizeLayoutRotation(180), 180);
    expect(PosTable.normalizeLayoutRotation(195), -165);
    expect(PosTable.normalizeLayoutRotation(345), -15);
    expect(PosTable.normalizeLayoutRotation(-195), 165);

    final table = PosTable.fromJson({
      'id': 'table-1',
      'restaurant_id': 'store-1',
      'table_number': 'T01',
      'layout_rotation': '345',
    });

    final rotated = table.copyWithLayout(
      table.layoutRect,
      layoutRotation: table.layoutRotation - 15,
    );

    expect(table.layoutRotation, -15);
    expect(rotated.layoutRotation, -30);
  });

  test('PosTable exposes reservation status separately from occupancy', () {
    final table = PosTable.fromJson({
      'id': 'table-1',
      'restaurant_id': 'store-1',
      'table_number': 'A1',
      'status': 'reserved',
    });

    expect(table.isReserved, isTrue);
    expect(table.isAvailable, isFalse);
    expect(table.isOccupied, isFalse);
  });
}
