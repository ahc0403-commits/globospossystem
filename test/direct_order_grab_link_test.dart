import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_staff_service.dart';

void main() {
  test('delivery share links accept every provider and reject unsafe URLs', () {
    expect(
      normalizeGrabTrackingUrl('grab.com/share/abc'),
      'https://grab.com/share/abc',
    );
    expect(
      normalizeGrabTrackingUrl('https://grab.onelink.me/abc'),
      'https://grab.onelink.me/abc',
    );
    expect(
      normalizeDeliveryTrackingUrl('https://be.example/track/abc'),
      'https://be.example/track/abc',
    );
    expect(
      normalizeDeliveryTrackingUrl('https://other.example/share'),
      'https://other.example/share',
    );
    expect(normalizeDeliveryTrackingUrl('javascript:alert(1)'), isNull);
    expect(
      normalizeDeliveryTrackingUrl('https://user:password@example.com'),
      isNull,
    );
    expect(normalizeDeliveryTrackingUrl('https://bad.example/a b'), isNull);
    expect(normalizeGrabTrackingUrl('http://grab.com/share/abc'), isNull);
  });
}
