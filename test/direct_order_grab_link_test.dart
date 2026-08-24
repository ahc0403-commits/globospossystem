import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_staff_service.dart';

void main() {
  test('Grab share links are normalized and invalid hosts are rejected', () {
    expect(
      normalizeGrabTrackingUrl('grab.com/share/abc'),
      'https://grab.com/share/abc',
    );
    expect(
      normalizeGrabTrackingUrl('https://grab.onelink.me/abc'),
      'https://grab.onelink.me/abc',
    );
    expect(normalizeGrabTrackingUrl('grand.com'), isNull);
    expect(normalizeGrabTrackingUrl('http://grab.com/share/abc'), isNull);
  });
}
