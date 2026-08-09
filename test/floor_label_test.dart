import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/floor_label.dart';

void main() {
  test('stored floor labels map to the new display labels', () {
    expect(displayFloorLabel('1F'), 'G');
    expect(displayFloorLabel('2F'), '1F');
    expect(displayFloorLabel('3F'), '2F');
    expect(displayFloorLabel('Kitchen'), 'KITCHEN');
  });

  test('display floor labels round trip to existing stored routing keys', () {
    for (final stored in ['1F', '2F', '3F']) {
      expect(storedFloorLabel(displayFloorLabel(stored)), stored);
    }
  });
}
