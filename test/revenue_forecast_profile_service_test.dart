import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/report/revenue_forecast/revenue_forecast_engine.dart';
import 'package:globos_pos_system/features/report/revenue_forecast/revenue_forecast_profile_service.dart';

void main() {
  test('restaurant profile preserves floor and capacity values', () {
    const profile = RestaurantForecastProfile(
      floors: [
        RestaurantFloorCapacity(
          label: '1F',
          tableCount: 12,
          serviceUnitsPerHour: 22.5,
        ),
        RestaurantFloorCapacity(
          label: '2F',
          tableCount: 8,
          serviceUnitsPerHour: 13,
        ),
      ],
      seatedToFirstServeMinutes: 14,
      diningMinutes: 48,
      paymentWaitMinutes: 6,
      cleanupMinutes: 5,
      kitchenUnitsPerHour: 31,
      checkerUnitsPerHour: 27,
      operatingMinutesPerDay: 720,
      operatingWeekdays: {1, 2, 3, 4, 5, 6},
      averageTicketVnd: 285000,
    );

    final decoded = restaurantProfileFromJson(restaurantProfileToJson(profile));

    expect(decoded.floors, hasLength(2));
    expect(decoded.floors.last.label, '2F');
    expect(decoded.floors.last.tableCount, 8);
    expect(decoded.floors.first.serviceUnitsPerHour, 22.5);
    expect(decoded.tableCycleMinutes, 73);
    expect(decoded.operatingWeekdays, {1, 2, 3, 4, 5, 6});
    expect(decoded.averageTicketVnd, 285000);
  });

  test('Photo profile preserves configurable values only', () {
    const profile = PhotoForecastProfile(
      machineCount: 3,
      operatingMinutesPerDay: 780,
      operatingWeekdays: {2, 3, 4, 5, 6, 7},
      freeServiceSessionsPerDay: 4,
    );

    final json = photoProfileToJson(profile);
    final decoded = photoProfileFromJson(json);

    expect(decoded.machineCount, 3);
    expect(decoded.operatingMinutesPerDay, 780);
    expect(decoded.operatingWeekdays, {2, 3, 4, 5, 6, 7});
    expect(decoded.freeServiceSessionsPerDay, 4);
    expect(json, isNot(contains('session_minutes')));
    expect(json, isNot(contains('revenue_per_session_vnd')));
    expect(photoSessionMinutes, 8);
    expect(photoRevenuePerPaidSessionVnd, 85000);
  });

  test('profile JSON rejects missing or duplicate operating weekdays', () {
    expect(
      () => photoProfileFromJson({
        'machine_count': 1,
        'operating_minutes_per_day': 720,
        'free_service_sessions_per_day': 0,
      }),
      throwsFormatException,
    );
    expect(
      () => photoProfileFromJson({
        'machine_count': 1,
        'operating_minutes_per_day': 720,
        'operating_weekdays': [1, 1, 7],
        'free_service_sessions_per_day': 0,
      }),
      throwsFormatException,
    );
  });
}
