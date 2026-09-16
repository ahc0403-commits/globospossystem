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
        'first_serve_sample_count': 300,
        'average_first_serve_seconds': 720,
        'dining_order_count': 280,
        'average_dining_seconds': 2700,
        'forecast_hourly_orders': [
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
          {
            'hour': '2026-08-09T10:00:00',
            'order_count': 8,
            'completed_count': 6,
          },
          {
            'hour': '2026-08-09T19:00:00',
            'order_count': 10,
            'completed_count': 8,
          },
        ],
      },
      observations: observations,
      periodStart: DateTime.utc(2026, 8, 8),
      periodEnd: DateTime.utc(2026, 9, 11),
    );

    expect(defaults, isNotNull);
    final profile = defaults!.profile;
    expect(profile.floors, hasLength(2));
    expect(profile.floors[0].label, 'G');
    expect(profile.floors[0].tableCount, 2);
    expect(profile.floors[1].label, '1F');
    expect(profile.floors[1].tableCount, 1);
    expect(profile.floors[0].serviceUnitsPerHour, closeTo(7, 0.001));
    expect(profile.floors[1].serviceUnitsPerHour, closeTo(3.5, 0.001));
    expect(profile.seatedToFirstServeMinutes, 12);
    expect(profile.diningMinutes, 45);
    expect(profile.paymentWaitMinutes, 0);
    expect(profile.cleanupMinutes, 0);
    expect(profile.kitchenUnitsPerHour, 10.5);
    expect(profile.checkerUnitsPerHour, 10.5);
    expect(profile.operatingMinutesPerDay, 660);
    expect(profile.operatingWeekdays, {1, 2, 3, 4, 5, 6, 7});
    expect(profile.averageTicketVnd, 280000);
    expect(defaults.usesMeasuredOperations, isTrue);
    expect(defaults.usesFallbackAssumptions, isFalse);
    expect(defaults.hasUnavailableInputs, isTrue);
    expect(
      defaults
          .evidenceFor(RevenueForecastInputField.firstServeMinutes)
          .sampleCount,
      300,
    );
    expect(
      defaults.evidenceFor(RevenueForecastInputField.paymentWaitMinutes).source,
      RevenueForecastInputSource.unavailable,
    );
    expect(
      defaults.evidenceFor(RevenueForecastInputField.averageTicket).source,
      RevenueForecastInputSource.selectedPeriodAverage,
    );
  });

  test('never injects fixed assumptions when measurements are unavailable', () {
    final defaults = deriveRestaurantForecastDefaults(
      tables: const [
        {'id': 't1', 'floor_label': '1F'},
      ],
      operations: const {
        // Legacy operation duration is intentionally not treated as the
        // seated-to-first-serve metric.
        'average_operation_seconds': 900,
      },
      observations: const [],
    );

    expect(defaults, isNotNull);
    final profile = defaults!.profile;
    expect(profile.seatedToFirstServeMinutes, 0);
    expect(profile.diningMinutes, 0);
    expect(profile.paymentWaitMinutes, 0);
    expect(profile.cleanupMinutes, 0);
    expect(profile.kitchenUnitsPerHour, 0);
    expect(profile.checkerUnitsPerHour, 0);
    expect(profile.operatingMinutesPerDay, 0);
    expect(profile.averageTicketVnd, 0);
    expect(profile.floors.single.serviceUnitsPerHour, 0);
    expect(defaults.usesFallbackAssumptions, isFalse);
    expect(defaults.hasUnavailableInputs, isTrue);
    for (final field in RevenueForecastInputField.values) {
      final expected =
          field == RevenueForecastInputField.floorLabel ||
              field == RevenueForecastInputField.tableCount
          ? RevenueForecastInputSource.registeredConfiguration
          : RevenueForecastInputSource.unavailable;
      expect(defaults.evidenceFor(field).source, expected);
    }
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
