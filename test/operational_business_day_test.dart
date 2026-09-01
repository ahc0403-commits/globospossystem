import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/time_utils.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/emergency_fulfillment_provider.dart';

void main() {
  test('Vietnam business day uses UTC+7 midnight and exclusive end', () {
    final beforeMidnight = TimeUtils.currentVietnamBusinessDay(
      nowUtc: DateTime.utc(2026, 9, 1, 16, 59, 59),
    );
    final afterMidnight = TimeUtils.currentVietnamBusinessDay(
      nowUtc: DateTime.utc(2026, 9, 1, 17),
    );

    expect(beforeMidnight.dateKey, '2026-09-01');
    expect(beforeMidnight.startUtc, DateTime.utc(2026, 8, 31, 17));
    expect(beforeMidnight.endUtc, DateTime.utc(2026, 9, 1, 17));
    expect(afterMidnight.dateKey, '2026-09-02');
    expect(afterMidnight.startUtc, beforeMidnight.endUtc);
    expect(afterMidnight.endUtc, DateTime.utc(2026, 9, 2, 17));
  });

  test('business-day refresh fires just after the next Vietnam midnight', () {
    final now = DateTime.utc(2026, 9, 1, 16, 59, 59, 500);
    final window = TimeUtils.currentVietnamBusinessDay(nowUtc: now);

    expect(window.refreshDelay(now), const Duration(milliseconds: 1500));
  });

  test('KDS snapshot retries back off without requiring another sign-in', () {
    expect(emergencySnapshotRetryDelay(1), const Duration(seconds: 2));
    expect(emergencySnapshotRetryDelay(2), const Duration(seconds: 5));
    expect(emergencySnapshotRetryDelay(3), const Duration(seconds: 15));
    expect(emergencySnapshotRetryDelay(20), const Duration(seconds: 15));
  });
}
