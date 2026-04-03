import 'package:timezone/timezone.dart' as tz;
import 'package:timezone/data/latest.dart' as tz_data;

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
      tzDt.year, tzDt.month, tzDt.day,
      tzDt.hour, tzDt.minute, tzDt.second,
    );
  }

  /// 현재 베트남 시간
  static DateTime nowVietnam() => toVietnam(DateTime.now().toUtc());

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
  static String formatDateTime(DateTime utc) => '${formatDate(utc)} ${formatTime(utc)}';
}
