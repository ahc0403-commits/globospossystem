import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/report/revenue_forecast/revenue_forecast_engine.dart';

List<RevenueForecastObservation> _observations({
  int days = 56,
  double base = 1000000,
  double dailyGrowth = 10000,
  double dineInShare = 0.8,
}) => [
  for (var index = 0; index < days; index++)
    RevenueForecastObservation(
      date: DateTime.utc(2026, 1, 1).add(Duration(days: index)),
      revenueVnd:
          base +
          dailyGrowth * index +
          (DateTime.utc(2026, 1, 1).add(Duration(days: index)).weekday ==
                  DateTime.saturday
              ? 100000
              : 0),
      dineInRevenueVnd:
          (base +
              dailyGrowth * index +
              (DateTime.utc(2026, 1, 1).add(Duration(days: index)).weekday ==
                      DateTime.saturday
                  ? 100000
                  : 0)) *
          dineInShare,
    ),
];

RestaurantForecastProfile _restaurantProfile({
  double kitchenPerHour = 20,
  double checkerPerHour = 20,
  double floorPerHour = 20,
  int tables = 20,
  int operatingMinutes = 600,
  Set<int> operatingWeekdays = const {1, 2, 3, 4, 5, 6, 7},
  double averageTicket = 100000,
}) => RestaurantForecastProfile(
  floors: [
    RestaurantFloorCapacity(
      label: '1F',
      tableCount: tables,
      serviceUnitsPerHour: floorPerHour,
    ),
  ],
  seatedToFirstServeMinutes: 15,
  diningMinutes: 45,
  paymentWaitMinutes: 5,
  cleanupMinutes: 5,
  kitchenUnitsPerHour: kitchenPerHour,
  checkerUnitsPerHour: checkerPerHour,
  operatingMinutesPerDay: operatingMinutes,
  operatingWeekdays: operatingWeekdays,
  averageTicketVnd: averageTicket,
);

void main() {
  const engine = RevenueForecastEngine();

  group('restaurant forecast', () {
    test('recovers a positive trend and never exceeds capacity', () {
      final observations = _observations();
      final result = engine.forecastRestaurant(
        observations: observations,
        trainingStart: observations.first.date,
        trainingEnd: observations.last.date,
        forecastEnd: DateTime.utc(2026, 5, 31),
        profile: _restaurantProfile(kitchenPerHour: 12, checkerPerHour: 9),
      );

      expect(result.regression.coefficients[1], closeTo(10000, 0.001));
      expect(result.backtest.foldCount, 28);
      expect(result.backtest.mae, closeTo(0, 0.01));
      expect(result.backtest.beatsWeekdayBaseline, isTrue);
      expect(result.days, isNotEmpty);
      expect(
        result.days.every(
          (day) => day.forecastRevenueVnd <= day.capacityRevenueVnd + 0.001,
        ),
        isTrue,
      );
      expect(result.recommendations, hasLength(6));
      expect(
        result.recommendations.every(
          (recommendation) =>
              recommendation.extraRevenueVnd >= 0 &&
              recommendation.extraServedUnits >= 0,
        ),
        isTrue,
      );
    });

    test(
      'does not invent uplift when demand is below every resource limit',
      () {
        final observations = _observations(base: 100000, dailyGrowth: 0);
        final result = engine.forecastRestaurant(
          observations: observations,
          trainingStart: observations.first.date,
          trainingEnd: observations.last.date,
          forecastEnd: DateTime.utc(2026, 4, 30),
          profile: _restaurantProfile(
            kitchenPerHour: 100,
            checkerPerHour: 100,
            floorPerHour: 100,
            tables: 100,
          ),
        );

        expect(
          result.recommendations.every(
            (recommendation) => recommendation.extraRevenueVnd < 0.01,
          ),
          isTrue,
        );
      },
    );

    test('reports another bottleneck when kitchen alone is improved', () {
      final observations = _observations(base: 8000000, dailyGrowth: 0);
      final result = engine.forecastRestaurant(
        observations: observations,
        trainingStart: observations.first.date,
        trainingEnd: observations.last.date,
        forecastEnd: DateTime.utc(2026, 4, 30),
        profile: _restaurantProfile(
          kitchenPerHour: 8,
          checkerPerHour: 5,
          floorPerHour: 30,
        ),
      );
      final kitchen = result.recommendations.singleWhere(
        (recommendation) =>
            recommendation.kind == ForecastRecommendationKind.kitchen,
      );

      expect(kitchen.extraRevenueVnd, closeTo(0, 0.01));
      expect(kitchen.nextBottleneck, 'checker');
    });

    test('classifies an unreachable monthly target as capacity exceeded', () {
      final observations = _observations(base: 3000000, dailyGrowth: 50000);
      final result = engine.forecastRestaurant(
        observations: observations,
        trainingStart: observations.first.date,
        trainingEnd: observations.last.date,
        forecastEnd: DateTime.utc(2026, 8, 31),
        profile: _restaurantProfile(kitchenPerHour: 5, checkerPerHour: 5),
      );

      expect(result.goals.first.status, ForecastGoalStatus.capacityExceeded);
      expect(result.goals.first.firstReachedMonth, isNull);
    });
  });

  group('Photo forecast', () {
    test('uses 8 minutes and 85,000 VND with no recommendations', () {
      final observations = _observations(
        base: 85 * photoRevenuePerPaidSessionVnd,
        dailyGrowth: 0,
        dineInShare: 0,
      );
      final result = engine.forecastPhoto(
        observations: observations,
        trainingStart: observations.first.date,
        trainingEnd: observations.last.date,
        forecastEnd: DateTime.utc(2026, 3, 31),
        profile: const PhotoForecastProfile(
          machineCount: 1,
          operatingMinutesPerDay: 720,
          operatingWeekdays: {1, 2, 3, 4, 5, 6, 7},
        ),
      );

      expect(result.days.first.capacityRevenueVnd, 7650000);
      expect(result.days.first.servedUnits, closeTo(85, 0.001));
      expect(result.recommendations, isEmpty);
      expect(result.usesEquivalentPhotoSessions, isTrue);
    });

    test('free service sessions consume the same machine capacity', () {
      final observations = _observations(
        base: 100 * photoRevenuePerPaidSessionVnd,
        dailyGrowth: 0,
        dineInShare: 0,
      );
      final result = engine.forecastPhoto(
        observations: observations,
        trainingStart: observations.first.date,
        trainingEnd: observations.last.date,
        forecastEnd: DateTime.utc(2026, 3, 1),
        profile: const PhotoForecastProfile(
          machineCount: 1,
          operatingMinutesPerDay: 720,
          operatingWeekdays: {1, 2, 3, 4, 5, 6, 7},
          freeServiceSessionsPerDay: 10,
        ),
      );

      expect(result.days.first.servedUnits, closeTo(80, 0.001));
      expect(
        result.days.first.forecastRevenueVnd,
        closeTo(80 * photoRevenuePerPaidSessionVnd, 0.001),
      );
    });

    test('closed days do not force equivalent-session fallback', () {
      final start = DateTime.utc(2026, 1, 1);
      final end = start.add(const Duration(days: 41));
      final observations = <RevenueForecastObservation>[
        for (
          var date = start;
          !date.isAfter(end);
          date = date.add(const Duration(days: 1))
        )
          if (date.weekday != DateTime.sunday)
            RevenueForecastObservation(
              date: date,
              revenueVnd: 10 * photoRevenuePerPaidSessionVnd,
              units: 10,
            ),
      ];
      final result = engine.forecastPhoto(
        observations: observations,
        trainingStart: start,
        trainingEnd: end,
        forecastEnd: DateTime.utc(2026, 3, 31),
        profile: const PhotoForecastProfile(
          machineCount: 1,
          operatingMinutesPerDay: 720,
          operatingWeekdays: {
            DateTime.monday,
            DateTime.tuesday,
            DateTime.wednesday,
            DateTime.thursday,
            DateTime.friday,
            DateTime.saturday,
          },
        ),
      );

      expect(result.usesEquivalentPhotoSessions, isFalse);
      expect(
        result.days
            .where((day) => day.date.weekday == DateTime.sunday)
            .every(
              (day) =>
                  day.forecastRevenueVnd == 0 && day.bottleneck == 'closed',
            ),
        isTrue,
      );
    });
  });

  group('validation', () {
    test('rejects a training range shorter than 28 days', () {
      final observations = _observations(days: 27);
      expect(
        () => engine.forecastRestaurant(
          observations: observations,
          trainingStart: observations.first.date,
          trainingEnd: observations.last.date,
          forecastEnd: DateTime.utc(2026, 3, 31),
          profile: _restaurantProfile(),
        ),
        throwsA(
          isA<ForecastValidationException>().having(
            (error) => error.code,
            'code',
            'TRAINING_PERIOD_TOO_SHORT',
          ),
        ),
      );
    });

    test('rejects missing calendar days instead of silently filling zero', () {
      final observations = _observations()..removeAt(10);
      expect(
        () => engine.forecastRestaurant(
          observations: observations,
          trainingStart: DateTime.utc(2026, 1, 1),
          trainingEnd: DateTime.utc(2026, 2, 25),
          forecastEnd: DateTime.utc(2026, 3, 31),
          profile: _restaurantProfile(),
        ),
        throwsA(
          isA<ForecastValidationException>().having(
            (error) => error.code,
            'code',
            'TRAINING_DAYS_INCOMPLETE',
          ),
        ),
      );
    });

    test('rejects a Photo service reserve above physical capacity', () {
      final observations = _observations();
      expect(
        () => engine.forecastPhoto(
          observations: observations,
          trainingStart: observations.first.date,
          trainingEnd: observations.last.date,
          forecastEnd: DateTime.utc(2026, 3, 31),
          profile: const PhotoForecastProfile(
            machineCount: 1,
            operatingMinutesPerDay: 60,
            operatingWeekdays: {1, 2, 3, 4, 5, 6, 7},
            freeServiceSessionsPerDay: 8,
          ),
        ),
        throwsA(
          isA<ForecastValidationException>().having(
            (error) => error.code,
            'code',
            'PHOTO_SERVICE_EXCEEDS_CAPACITY',
          ),
        ),
      );
    });

    test('rejects impossible channel revenue and invalid observed units', () {
      final invalidDineIn = _observations()
        ..[0] = RevenueForecastObservation(
          date: DateTime.utc(2026, 1, 1),
          revenueVnd: 100,
          dineInRevenueVnd: 101,
        );
      expect(
        () => engine.forecastRestaurant(
          observations: invalidDineIn,
          trainingStart: invalidDineIn.first.date,
          trainingEnd: invalidDineIn.last.date,
          forecastEnd: DateTime.utc(2026, 3, 31),
          profile: _restaurantProfile(),
        ),
        throwsA(
          isA<ForecastValidationException>().having(
            (error) => error.code,
            'code',
            'INVALID_DINE_IN_REVENUE',
          ),
        ),
      );

      final invalidUnits = _observations()
        ..[0] = RevenueForecastObservation(
          date: DateTime.utc(2026, 1, 1),
          revenueVnd: 100,
          units: -1,
        );
      expect(
        () => engine.forecastPhoto(
          observations: invalidUnits,
          trainingStart: invalidUnits.first.date,
          trainingEnd: invalidUnits.last.date,
          forecastEnd: DateTime.utc(2026, 3, 31),
          profile: const PhotoForecastProfile(
            machineCount: 1,
            operatingMinutesPerDay: 720,
            operatingWeekdays: {1, 2, 3, 4, 5, 6, 7},
          ),
        ),
        throwsA(
          isA<ForecastValidationException>().having(
            (error) => error.code,
            'code',
            'INVALID_UNITS',
          ),
        ),
      );
    });

    test('rejects negative restaurant stage times', () {
      final observations = _observations();
      expect(
        () => engine.forecastRestaurant(
          observations: observations,
          trainingStart: observations.first.date,
          trainingEnd: observations.last.date,
          forecastEnd: DateTime.utc(2026, 3, 31),
          profile: _restaurantProfile().copyWith(seatedToFirstServeMinutes: -5),
        ),
        throwsA(
          isA<ForecastValidationException>().having(
            (error) => error.code,
            'code',
            'RESTAURANT_PROFILE_INVALID',
          ),
        ),
      );
    });

    test(
      'fills configured closed days with zero and forecasts zero capacity',
      () {
        final allRows = _observations(days: 42);
        final openRows = allRows
            .where((row) => row.date.weekday != DateTime.sunday)
            .toList(growable: false);
        final result = engine.forecastRestaurant(
          observations: openRows,
          trainingStart: allRows.first.date,
          trainingEnd: allRows.last.date,
          forecastEnd: DateTime.utc(2026, 3, 31),
          profile: _restaurantProfile(
            operatingWeekdays: const {
              DateTime.monday,
              DateTime.tuesday,
              DateTime.wednesday,
              DateTime.thursday,
              DateTime.friday,
              DateTime.saturday,
            },
          ),
        );

        final closedDays = result.days.where(
          (day) => day.date.weekday == DateTime.sunday,
        );
        expect(closedDays, isNotEmpty);
        expect(
          closedDays.every(
            (day) =>
                day.forecastRevenueVnd == 0 &&
                day.capacityRevenueVnd == 0 &&
                day.bottleneck == 'closed',
          ),
          isTrue,
        );
      },
    );

    test('rejects positive activity on a configured closed day', () {
      final observations = _observations(days: 42);
      expect(
        () => engine.forecastRestaurant(
          observations: observations,
          trainingStart: observations.first.date,
          trainingEnd: observations.last.date,
          forecastEnd: DateTime.utc(2026, 3, 31),
          profile: _restaurantProfile(
            operatingWeekdays: const {
              DateTime.monday,
              DateTime.tuesday,
              DateTime.wednesday,
              DateTime.thursday,
              DateTime.friday,
              DateTime.saturday,
            },
          ),
        ),
        throwsA(
          isA<ForecastValidationException>().having(
            (error) => error.code,
            'code',
            'CLOSED_DAY_HAS_REVENUE',
          ),
        ),
      );
    });

    test('requires 28 actual operating days, not just calendar days', () {
      final start = DateTime.utc(2026, 1, 1);
      final end = start.add(const Duration(days: 55));
      final observations = <RevenueForecastObservation>[
        for (
          var date = start;
          !date.isAfter(end);
          date = date.add(const Duration(days: 1))
        )
          if (date.weekday == DateTime.monday)
            RevenueForecastObservation(date: date, revenueVnd: 1000000),
      ];
      expect(
        () => engine.forecastRestaurant(
          observations: observations,
          trainingStart: start,
          trainingEnd: end,
          forecastEnd: DateTime.utc(2026, 3, 31),
          profile: _restaurantProfile(
            operatingWeekdays: const {DateTime.monday},
          ),
        ),
        throwsA(
          isA<ForecastValidationException>().having(
            (error) => error.code,
            'code',
            'TRAINING_PERIOD_TOO_SHORT',
          ),
        ),
      );
    });

    test('reports insufficient backtest evidence at exactly 28 days', () {
      final observations = _observations(days: 28);
      final result = engine.forecastRestaurant(
        observations: observations,
        trainingStart: observations.first.date,
        trainingEnd: observations.last.date,
        forecastEnd: DateTime.utc(2026, 3, 31),
        profile: _restaurantProfile(),
      );

      expect(result.backtest.foldCount, 0);
      expect(result.backtest.mae, isNull);
      expect(result.backtest.beatsWeekdayBaseline, isNull);
    });
  });
}
