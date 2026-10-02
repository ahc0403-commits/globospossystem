import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/inventory_purchase/inventory_safety_stock.dart';

void main() {
  test('physical quantities round-trip independently of purchase packages', () {
    expect(InventorySafetyStock.input(5000, 'g'), '5');
    expect(InventorySafetyStock.input(12988, 'ml'), '12.988');
    expect(InventorySafetyStock.input(20, 'ea'), '20');
    expect(InventorySafetyStock.input(0, 'g'), '0');
    expect(InventorySafetyStock.input(null, 'ml'), '');
    expect(InventorySafetyStock.input(0.001, 'g'), '0.000001');
    expect(InventorySafetyStock.toBase(5, 'g'), 5000);
    expect(InventorySafetyStock.toBase(25, 'ml'), 25000);
    expect(InventorySafetyStock.toBase(4, 'ea'), 4);
    expect(InventorySafetyStock.parse('1,25'), 1.25);
    expect(InventorySafetyStock.parse('0.000001'), 0.000001);
    for (final invalid in [
      '',
      'text',
      'NaN',
      'Infinity',
      '1,000.5',
      '1.0000001',
    ]) {
      expect(InventorySafetyStock.parse(invalid), isNull, reason: invalid);
    }
    expect(InventorySafetyStock.isValid(0.000001, 'ea'), isFalse);
    expect(InventorySafetyStock.isValid(0.001, 'ea'), isTrue);
    expect(InventorySafetyStock.isValid(0.000001, 'g'), isTrue);
    expect(InventorySafetyStock.isValid(-1, 'g'), isFalse);
    expect(InventorySafetyStock.isValid(double.infinity, 'g'), isFalse);
    expect(InventorySafetyStock.isValid(1000000, 'g'), isFalse);
  });

  test(
    'an unset threshold and configured zero have distinct warning behavior',
    () {
      expect(InventorySafetyStock.needsReorder(-1, null), isFalse);
      expect(InventorySafetyStock.needsReorder(0, 0), isTrue);
      expect(InventorySafetyStock.needsReorder(5000, 5000), isTrue);
      expect(InventorySafetyStock.needsReorder(4999, 5000), isTrue);
      expect(InventorySafetyStock.needsReorder(5001, 5000), isFalse);
    },
  );
}
