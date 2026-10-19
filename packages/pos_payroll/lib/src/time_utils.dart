import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;

class VietnamBusinessDayWindow {
  const VietnamBusinessDayWindow({
    required this.dateKey,
    required this.startUtc,
    required this.endUtc,
  });

  final String dateKey;
  final DateTime startUtc;
  final DateTime endUtc;

  String get startIso8601 => startUtc.toIso8601String();
  String get endIso8601 => endUtc.toIso8601String();

  Duration refreshDelay(DateTime nowUtc) {
    final remaining = endUtc.difference(nowUtc.toUtc());
    if (remaining.isNegative) return const Duration(seconds: 1);
    return remaining + const Duration(seconds: 1);
  }
}

/// RULES.md: DB는 UTC. UI에서만 Asia/Ho_Chi_Minh 변환
class TimeUtils {
  static bool _initialized = false;

  static void init() {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    _initialized = true;
  }

  /// UTC DateTime → 베트남 시간 (Asia/Ho_Chi_Minh, UTC+7)
  static DateTime toVietnam(DateTime utc) {
    init();
    final location = tz.getLocation('Asia/Ho_Chi_Minh');
    final tzDt = tz.TZDateTime.from(utc.toUtc(), location);
    return DateTime(
      tzDt.year,
      tzDt.month,
      tzDt.day,
      tzDt.hour,
      tzDt.minute,
      tzDt.second,
    );
  }

  /// 현재 베트남 시간
  static DateTime nowVietnam() => toVietnam(DateTime.now().toUtc());

  /// Current Vietnam civil-day bounds represented in UTC for database reads.
  static VietnamBusinessDayWindow currentVietnamBusinessDay({
    DateTime? nowUtc,
  }) {
    final observedUtc = (nowUtc ?? DateTime.now()).toUtc();
    final vietnamNow = toVietnam(observedUtc);
    final localStart = DateTime(
      vietnamNow.year,
      vietnamNow.month,
      vietnamNow.day,
    );
    final localEnd = DateTime(
      vietnamNow.year,
      vietnamNow.month,
      vietnamNow.day + 1,
    );
    final dateKey =
        '${localStart.year.toString().padLeft(4, '0')}-'
        '${localStart.month.toString().padLeft(2, '0')}-'
        '${localStart.day.toString().padLeft(2, '0')}';
    return VietnamBusinessDayWindow(
      dateKey: dateKey,
      startUtc: vietnamWallTimeToUtc(localStart),
      endUtc: vietnamWallTimeToUtc(localEnd),
    );
  }

  /// Vietnam wall-clock value → UTC for database writes.
  static DateTime vietnamWallTimeToUtc(DateTime value) {
    init();
    final location = tz.getLocation('Asia/Ho_Chi_Minh');
    return tz.TZDateTime(
      location,
      value.year,
      value.month,
      value.day,
      value.hour,
      value.minute,
      value.second,
    ).toUtc();
  }

  /// 날짜 문자열
  static String formatDate(DateTime utc) {
    final vn = toVietnam(utc);
    return '${vn.year}-${vn.month.toString().padLeft(2, '0')}-${vn.day.toString().padLeft(2, '0')}';
  }

  /// 시간 문자열
  static String formatTime(DateTime utc) {
    final vn = toVietnam(utc);
    return '${vn.hour.toString().padLeft(2, '0')}:${vn.minute.toString().padLeft(2, '0')}';
  }

  /// 날짜+시간
  static String formatDateTime(DateTime utc) =>
      '${formatDate(utc)} ${formatTime(utc)}';
}
