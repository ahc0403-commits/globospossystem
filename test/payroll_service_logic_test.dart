import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/payroll_service.dart';

Map<String, dynamic> _log(String type, String loggedAt) => {
  'type': type,
  'logged_at': loggedAt,
};

void main() {
  group('PayrollService attendance pairing', () {
    test('Mai 11:27 to 16:15 is paid as 4.8 hours', () {
      final service = PayrollService();
      final pairs = service.pairLogs([
        _log('clock_in', '2026-07-27T04:27:00Z'),
        _log('clock_out', '2026-07-27T09:15:00Z'),
      ]);

      expect(pairs, hasLength(1));
      final clockIn = pairs.single.$1;
      final clockOut = pairs.single.$2;
      expect(clockIn, isNotNull);
      expect(clockOut, isNotNull);

      final hours = clockOut!.difference(clockIn!).inMinutes / 60;
      expect(hours, closeTo(4.8, 0.000001));
      expect(service.calcHourlyAmount(hours, 10000), 48000);
    });

    test('duplicate events use first clock-in and last clock-out', () {
      final service = PayrollService();
      final pairs = service.pairLogs([
        _log('clock_in', '2026-07-27T01:00:00Z'),
        _log('clock_in', '2026-07-27T01:05:00Z'),
        _log('clock_out', '2026-07-27T01:06:00Z'),
        _log('clock_out', '2026-07-27T02:05:00Z'),
      ]);

      expect(pairs, hasLength(1));
      expect(pairs.single.$1, DateTime(2026, 7, 27, 8));
      expect(pairs.single.$2, DateTime(2026, 7, 27, 9, 5));
    });

    test('orphan clock-out is review-only and has no payable duration', () {
      final pairs = PayrollService().pairLogs([
        _log('clock_out', '2026-07-27T09:15:00Z'),
      ]);

      expect(pairs, hasLength(1));
      expect(pairs.single.$1, isNull);
      expect(pairs.single.$2, isNotNull);
    });

    test('historical second shift on the same day cannot double payroll', () {
      final pairs = PayrollService().pairLogs([
        _log('clock_in', '2026-07-27T01:00:00Z'),
        _log('clock_out', '2026-07-27T03:00:00Z'),
        _log('clock_in', '2026-07-27T05:00:00Z'),
        _log('clock_out', '2026-07-27T07:00:00Z'),
      ]);

      expect(pairs, hasLength(1));
      expect(pairs.single.$1, DateTime(2026, 7, 27, 8));
      expect(pairs.single.$2, DateTime(2026, 7, 27, 14));
    });

    test('overnight shift remains one payable pair', () {
      final pairs = PayrollService().pairLogs([
        _log('clock_in', '2026-07-27T16:00:00Z'),
        _log('clock_out', '2026-07-27T19:00:00Z'),
      ]);

      expect(pairs, hasLength(1));
      expect(pairs.single.$1, DateTime(2026, 7, 27, 23));
      expect(pairs.single.$2, DateTime(2026, 7, 28, 2));
    });
  });

  test('night hours are calculated across midnight minute by minute', () {
    final result = PayrollService().calcRuleBasedHourlyAmount(
      clockIn: DateTime(2026, 7, 27, 21, 30),
      clockOut: DateTime(2026, 7, 28, 0, 30),
      hourlyRate: 60000,
      nightStartMinute: 22 * 60,
      nightMultiplier: 1.3,
      holidayMultiplier: 3,
      excludeSunday: true,
      holidays: const {},
    );

    expect(result.nightHours, 2.5);
    expect(result.holidayHours, 0);
    expect(result.amount, 225000);
  });
}
