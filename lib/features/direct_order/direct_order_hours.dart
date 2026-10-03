// Vietnam remains UTC+7 throughout the year. Server time controls acceptance.
DateTime directOrderNextHoursChange(DateTime now) {
  final utc = now.toUtc();
  final local = utc.add(const Duration(hours: 7));
  final today = DateTime.utc(local.year, local.month, local.day);
  final next = local.hour < 11
      ? today.add(const Duration(hours: 11))
      : local.hour < 22
      ? today.add(const Duration(hours: 22))
      : today.add(const Duration(days: 1, hours: 11));
  return next.subtract(const Duration(hours: 7));
}
