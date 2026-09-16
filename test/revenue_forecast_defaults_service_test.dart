import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/report/revenue_forecast/revenue_forecast_defaults_service.dart';
import 'package:globos_pos_system/features/report/revenue_forecast/revenue_forecast_engine.dart';

void main() {
  test('derives floor and table defaults from registered store tables', () {
    final start = DateTime.utc(2026, 8, 8);
    final observations = List.generate(
      35,
      (index) => RevenueForecastObservation(
        date: start.add(Duration(days: index)),
        revenueVnd: 3500000,
        dineInRevenueVnd: 2800000,
        units: 10,
      ),
    );

    final defaults = deriveRestaurantForecastDefaults(
      tables: const [
        {'id': 't1', 'floor_label': '1F'},
        {'id': 't2', 'floor_label': '1F'},
        {'id': 't3', 'floor_label': '2F'},
      ],
      operations: const {
        'order_count': 350,
        'average_operation_seconds': 900,
        'average_dining_seconds': 2700,
        'hourly_orders': [
          {
            'hour': '2026-08-08T10:00:00',
            'order_count': 12,
            'completed_count': 10,
          },
          {
            'hour': '2026-08-08T21:00:00',
            'order_count': 20,
            'completed_count': 18,
          },
        ],
      },
      observations: observations,
    );

    expect(defaults, isNotNull);
    final profile = defaults!.profile;
    expect(profile.floors, hasLength(2));
    expect(profile.floors[0].label, 'G');
    expect(profile.floors[0].tableCount, 2);
    expect(profile.floors[1].label, '1F');
    expect(profile.floors[1].tableCount, 1);
    expect(profile.floors[0].serviceUnitsPerHour, closeTo(13.8, 0.001));
    expect(profile.floors[1].serviceUnitsPerHour, closeTo(6.9, 0.001));
    expect(profile.seatedToFirstServeMinutes, 15);
    expect(profile.diningMinutes, 45);
    expect(profile.operatingMinutesPerDay, 720);
    expect(profile.operatingWeekdays, {1, 2, 3, 4, 5, 6, 7});
    expect(profile.averageTicketVnd, 280000);
    expect(defaults.usesMeasuredOperations, isTrue);
    expect(defaults.usesFallbackAssumptions, isTrue);
  });

  test('returns no restaurant defaults when the store has no tables', () {
    final defaults = deriveRestaurantForecastDefaults(
      tables: const [],
      operations: const {},
      observations: const [],
    );

    expect(defaults, isNull);
  });
}
