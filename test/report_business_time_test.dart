import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';

void main() {
  test('UTC payment time is shown in Ho Chi Minh business time', () {
    final businessTime = toHoChiMinhBusinessTime(
      DateTime.parse('2026-08-08T05:00:00Z'),
    );

    expect(businessTime.year, 2026);
    expect(businessTime.month, 8);
    expect(businessTime.day, 8);
    expect(businessTime.hour, 12);
  });

  test('report date range uses Vietnam midnight and exclusive end', () {
    final range = reportUtcRange(
      DateTime(2026, 8, 8),
      DateTime(2026, 8, 8, 23, 59, 59),
    );

    expect(range.startUtc, DateTime.utc(2026, 8, 7, 17));
    expect(range.endExclusiveUtc, DateTime.utc(2026, 8, 8, 17));
  });
}
