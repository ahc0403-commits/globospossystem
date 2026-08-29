import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/payroll_service.dart';

Map<String, dynamic> _log(String type, String loggedAt) => {
  'type': type,
  'logged_at': loggedAt,
};

void main() {
  group('PayrollService attendance pairing', () {
    test('Mai 11:27 to 16:15 is paid as 4.8 scheduled-shift hours', () {
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

    test('backfilled clock-out then clock-in pairs by attendance time', () {
      final pairs = PayrollService().pairLogs([
        _log('clock_out', '2026-07-27T09:15:00Z'),
        _log('clock_in', '2026-07-27T04:27:00Z'),
      ]);

      expect(pairs, hasLength(1));
      expect(pairs.single.$1, DateTime(2026, 7, 27, 11, 27));
      expect(pairs.single.$2, DateTime(2026, 7, 27, 16, 15));
    });

    test('alternating events create separate split shifts on the same day', () {
      final pairs = PayrollService().pairLogs([
        _log('clock_in', '2026-07-27T01:00:00Z'),
        _log('clock_out', '2026-07-27T03:00:00Z'),
        _log('clock_in', '2026-07-27T05:00:00Z'),
        _log('clock_out', '2026-07-27T07:00:00Z'),
      ]);

      expect(pairs, hasLength(2));
      expect(pairs.first.$1, DateTime(2026, 7, 27, 8));
      expect(pairs.first.$2, DateTime(2026, 7, 27, 10));
      expect(pairs.last.$1, DateTime(2026, 7, 27, 12));
      expect(pairs.last.$2, DateTime(2026, 7, 27, 14));
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

  group('scheduled shift payroll', () {
    test('early arrival and checkout after a pre-22 shift are not payable', () {
      final result = PayrollService().calcScheduledRuleBasedHourlyAmount(
        clockIn: DateTime(2026, 8, 23, 8, 50),
        clockOut: DateTime(2026, 8, 23, 14, 7),
        configuredStartMinute: 9 * 60,
        hourlyRate: 30000,
        nightStartMinute: 22 * 60,
        nightMultiplier: 1.3,
        holidayMultiplier: 3,
        excludeSunday: true,
        holidays: const {},
      );

      expect(result.scheduledStart, DateTime(2026, 8, 23, 9));
      expect(result.scheduledEnd, DateTime(2026, 8, 23, 14));
      expect(result.hours, 5);
      expect(result.lateMinutes, 0);
      expect(result.amount, 150000);
    });

    test(
      'late arrival reduces payable time and records the same deduction',
      () {
        final result = PayrollService().calcScheduledRuleBasedHourlyAmount(
          clockIn: DateTime(2026, 8, 24, 9, 10),
          clockOut: DateTime(2026, 8, 24, 14),
          configuredStartMinute: 9 * 60,
          hourlyRate: 30000,
          nightStartMinute: 22 * 60,
          nightMultiplier: 1.3,
          holidayMultiplier: 3,
          excludeSunday: true,
          holidays: const {},
        );

        expect(result.hours, closeTo(4.83, 0.000001));
        expect(result.lateMinutes, 10);
        expect(result.amount, 145000);
      },
    );

    test('only work after 22:00 is added beyond the scheduled shift', () {
      final result = PayrollService().calcScheduledRuleBasedHourlyAmount(
        clockIn: DateTime(2026, 8, 24, 17, 53),
        clockOut: DateTime(2026, 8, 24, 22, 13),
        configuredStartMinute: 18 * 60,
        hourlyRate: 30000,
        nightStartMinute: 22 * 60,
        nightMultiplier: 1.3,
        holidayMultiplier: 3,
        excludeSunday: true,
        holidays: const {},
      );

      expect(result.scheduledStart, DateTime(2026, 8, 24, 18));
      expect(result.scheduledEnd, DateTime(2026, 8, 24, 22));
      expect(result.regularMinutes, 4 * 60);
      expect(result.overtimeMinutes, 13);
      expect(result.hours, closeTo(4.22, 0.000001));
      expect(result.nightHours, closeTo(0.22, 0.000001));
      expect(result.amount, 128450);
    });
  });
}
