Map<String, dynamic> posPayrollSnapshot({
  String storeId = 'photo-A',
  String employeeId = 'pos-employee',
  DateTime? from,
  DateTime? to,
  bool missingRule = false,
}) {
  from ??= DateTime(2026, 10, 1);
  to ??= DateTime(2026, 10, 15);
  final day = DateTime(from.year, from.month, from.day);
  final date = day.toIso8601String().substring(0, 10);
  return {
    'version': 1,
    'photo_store_id': storeId,
    'store_id': 'pos-A',
    'employee_id': employeeId,
    'from': from.toIso8601String().substring(0, 10),
    'to': to.toIso8601String().substring(0, 10),
    'generated_at': '2026-10-15T04:00:00Z',
    'staff': [
      {
        'user_id': employeeId,
        'full_name': 'Existing POS employee',
        'role': 'part_timer',
      },
    ],
    'logs': [
      for (final (index, type, hour, minute) in [
        (0, 'clock_in', 9, 0),
        (1, 'clock_out', 14, 0),
        (2, 'clock_in', 18, 0),
        (3, 'clock_out', 22, 30),
      ])
        {
          'id': 'event-$index',
          'restaurant_id': 'pos-A',
          'employee_id': employeeId,
          'user_id': employeeId,
          'type': type,
          'logged_at': DateTime.utc(
            day.year,
            day.month,
            day.day,
            hour - 7,
            minute,
          ).toIso8601String(),
          'users': {
            'id': employeeId,
            'full_name': 'Existing POS employee',
            'role': 'part_timer',
          },
        },
    ],
    'allowances': [
      {
        'id': 'allowance',
        'store_id': 'pos-A',
        'employee_id': employeeId,
        'work_date': date,
        'is_split_shift': true,
        'meal_allowance_amount': 25000,
        'parking_allowance_amount': 5000,
      },
    ],
    'holidays': <String>[],
    'hourly_rules': {
      employeeId: missingRule
          ? null
          : {
              'hourly_rate': 30000,
              'scheduled_start': '09:00',
              'night_start': '22:00',
              'night_multiplier': 1.3,
              'holiday_multiplier': 3,
              'exclude_sunday': true,
              'late_threshold_minutes': 60,
              'late_review_hourly_multiplier': 2,
            },
    },
  };
}

Map<String, dynamic> photoInput({
  String role = 'part_timer',
  double rate = 25000,
  String date = '2026-10-01',
  int start = 9,
  int end = 10,
  bool holiday = false,
  int days = 1,
}) {
  final data = posPayrollSnapshot();
  data['staff'] = [
    {
      'user_id': 'pos-employee',
      'full_name': 'Fixture',
      'role': role,
      'photo_policy': true,
      'pay_policies': [
        {
          'effective_from': '2000-01-01',
          'monthly_salary': 6500000,
          'standard_monthly_minutes': 12480,
          'overtime_multiplier': 1.5,
        },
      ],
    },
  ];
  data['hourly_rules'] = {
    'pos-employee': role == 'full_time'
        ? null
        : {
            'hourly_rate': rate,
            'scheduled_start': '09:00',
            'night_start': '22:00',
            'night_multiplier': 1.5,
            'holiday_multiplier': 3,
            'exclude_sunday': true,
          },
  };
  data['logs'] = [
    for (var d = 0; d < days; d++)
      for (final event in [('clock_in', start), ('clock_out', end)])
        {
          'id': '$d-${event.$1}',
          'restaurant_id': 'pos-A',
          'employee_id': 'pos-employee',
          'user_id': 'pos-employee',
          'type': event.$1,
          'logged_at': DateTime.parse(
            '${date}T00:00:00Z',
          ).add(Duration(days: d, hours: event.$2 - 7)).toIso8601String(),
          'users': {'id': 'pos-employee', 'full_name': 'Fixture', 'role': role},
        },
  ];
  data['holidays'] = holiday ? [date] : <String>[];
  data['allowances'] = <Map<String, dynamic>>[];
  return data;
}
