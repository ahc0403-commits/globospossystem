import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

void main() {
  test('real Storage/attendance fixture is a decodable bounded JPEG', () {
    final bytes = File(
      'scripts/resilience/fixtures/attendance.jpg',
    ).readAsBytesSync();
    expect(bytes.length, lessThan(5 * 1024));
    final decoded = img.decodeJpg(bytes);
    expect(decoded, isNotNull);
    expect(decoded!.width, 96);
    expect(decoded.height, 72);
  });
}
