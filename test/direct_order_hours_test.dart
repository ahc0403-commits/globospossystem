import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_hours.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_staff_service.dart';

void main() {
  test(
    'refresh deadlines use Vietnam time across midnight and UTC offsets',
    () {
      for (final entry in {
        '2026-10-03T10:59:59+07:00': '2026-10-03T04:00:00Z',
        '2026-10-03T11:00:00+07:00': '2026-10-03T15:00:00Z',
        '2026-10-03T21:59:59+07:00': '2026-10-03T15:00:00Z',
        '2026-10-03T22:00:00+07:00': '2026-10-04T04:00:00Z',
        '2026-10-04T00:00:00+07:00': '2026-10-04T04:00:00Z',
        '2026-10-03T04:00:00Z': '2026-10-03T15:00:00Z',
      }.entries) {
        expect(
          directOrderNextHoursChange(DateTime.parse(entry.key)),
          DateTime.parse(entry.value),
          reason: entry.key,
        );
      }
    },
  );

  test('scheduled closure disables manual reopen but stays configured', () {
    final closed = DirectOrderAvailability.fromJson(const {
      'configured': true,
      'enabled': true,
      'paused': true,
      'hours_open': false,
      'updated_at': null,
    });
    expect(closed.configured, isTrue);
    expect(closed.acceptingOrders, isFalse);
    expect(closed.canChange, isFalse);
    expect(
      () => DirectOrderAvailability.fromJson(const {
        'configured': true,
        'enabled': true,
        'paused': true,
        'hours_open': 'false',
        'updated_at': null,
      }),
      throwsException,
    );
  });
}
