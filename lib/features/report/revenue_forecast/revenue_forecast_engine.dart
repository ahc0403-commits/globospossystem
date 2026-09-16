import 'dart:math' as math;

const int photoSessionMinutes = 8;
const double photoRevenuePerPaidSessionVnd = 85000;
const int minimumForecastTrainingDays = 28;

enum ForecastBusinessType { restaurant, photo }

enum ForecastRecommendationKind {
  tableTurnover,
  kitchen,
  checker,
  floorService,
  nonDiningWait,
  operatingHours,
}

enum ForecastGoalStatus {
  reached,
  demandNotReached,
  capacityExceeded,
  insufficientEvidence,
}

class ForecastValidationException implements Exception {
  const ForecastValidationException(this.code);

  final String code;

  @override
  String toString() => code;
}

class RevenueForecastObservation {
  const RevenueForecastObservation({
    required this.date,
    required this.revenueVnd,
    this.dineInRevenueVnd = 0,
    this.units,
  });

  final DateTime date;
  final double revenueVnd;
  final double dineInRevenueVnd;
  final double? units;
}

class RestaurantFloorCapacity {
  const RestaurantFloorCapacity({
    required this.label,
    required this.tableCount,
    required this.serviceUnitsPerHour,
  });

  final String label;
  final int tableCount;
  final double serviceUnitsPerHour;

  RestaurantFloorCapacity copyWith({
    String? label,
    int? tableCount,
    double? serviceUnitsPerHour,
  }) => RestaurantFloorCapacity(
    label: label ?? this.label,
    tableCount: tableCount ?? this.tableCount,
    serviceUnitsPerHour: serviceUnitsPerHour ?? this.serviceUnitsPerHour,
  );
}

class RestaurantForecastProfile {
  const RestaurantForecastProfile({
    required this.floors,
    required this.seatedToFirstServeMinutes,
    required this.diningMinutes,
    required this.paymentWaitMinutes,
    required this.cleanupMinutes,
    required this.kitchenUnitsPerHour,
    required this.checkerUnitsPerHour,
    required this.operatingMinutesPerDay,
    required this.operatingWeekdays,
    required this.averageTicketVnd,
  });

  final List<RestaurantFloorCapacity> floors;
  final double seatedToFirstServeMinutes;
  final double diningMinutes;
  final double paymentWaitMinutes;
  final double cleanupMinutes;
  final double kitchenUnitsPerHour;
  final double checkerUnitsPerHour;
  final int operatingMinutesPerDay;
  final Set<int> operatingWeekdays;
  final double averageTicketVnd;

  double get tableCycleMinutes =>
      seatedToFirstServeMinutes +
      diningMinutes +
      paymentWaitMinutes +
      cleanupMinutes;

  RestaurantForecastProfile copyWith({
    List<RestaurantFloorCapacity>? floors,
    double? seatedToFirstServeMinutes,
    double? diningMinutes,
    double? paymentWaitMinutes,
    double? cleanupMinutes,
    double? kitchenUnitsPerHour,
    double? checkerUnitsPerHour,
    int? operatingMinutesPerDay,
    Set<int>? operatingWeekdays,
    double? averageTicketVnd,
  }) => RestaurantForecastProfile(
    floors: floors ?? this.floors,
    seatedToFirstServeMinutes:
        seatedToFirstServeMinutes ?? this.seatedToFirstServeMinutes,
    diningMinutes: diningMinutes ?? this.diningMinutes,
    paymentWaitMinutes: paymentWaitMinutes ?? this.paymentWaitMinutes,
    cleanupMinutes: cleanupMinutes ?? this.cleanupMinutes,
    kitchenUnitsPerHour: kitchenUnitsPerHour ?? this.kitchenUnitsPerHour,
    checkerUnitsPerHour: checkerUnitsPerHour ?? this.checkerUnitsPerHour,
    operatingMinutesPerDay:
        operatingMinutesPerDay ?? this.operatingMinutesPerDay,
    operatingWeekdays: operatingWeekdays ?? this.operatingWeekdays,
    averageTicketVnd: averageTicketVnd ?? this.averageTicketVnd,
  );
}

class PhotoForecastProfile {
  const PhotoForecastProfile({
    required this.machineCount,
    required this.operatingMinutesPerDay,
    required this.operatingWeekdays,
    this.freeServiceSessionsPerDay = 0,
  });

  final int machineCount;
  final int operatingMinutesPerDay;
  final Set<int> operatingWeekdays;
  final int freeServiceSessionsPerDay;
}

class ForecastRegression {
  const ForecastRegression({
    required this.coefficients,
    required this.centerDay,
    required this.rmse,
    required this.rSquared,
  });

  final List<double> coefficients;
  final double centerDay;
  final double rmse;
  final double rSquared;

  double predict(DateTime date, DateTime origin) {
    final day = _dateOnly(date).difference(_dateOnly(origin)).inDays.toDouble();
    final x = _predictors(day, centerDay, date.weekday);
    var value = 0.0;
    for (var i = 0; i < coefficients.length; i++) {
      value += coefficients[i] * x[i];
    }
    return math.max(0, value);
  }
}

class ForecastBacktestMetrics {
  const ForecastBacktestMetrics({
    required this.foldCount,
    this.mae,
    this.rmse,
    this.wape,
    this.bias,
    this.weekdayBaselineMae,
  });

  final int foldCount;
  final double? mae;
  final double? rmse;
  final double? wape;
  final double? bias;
  final double? weekdayBaselineMae;

  bool? get beatsWeekdayBaseline {
    if (mae == null || weekdayBaselineMae == null) return null;
    return mae! < weekdayBaselineMae!;
  }
}

class ForecastDayResult {
  const ForecastDayResult({
    required this.date,
    required this.demandUnits,
    required this.servedUnits,
    required this.demandRevenueVnd,
    required this.forecastRevenueVnd,
    required this.capacityRevenueVnd,
    required this.bottleneck,
  });

  final DateTime date;
  final double demandUnits;
  final double servedUnits;
  final double demandRevenueVnd;
  final double forecastRevenueVnd;
  final double capacityRevenueVnd;
  final String bottleneck;
}

class ForecastMonthResult {
  const ForecastMonthResult({
    required this.month,
    required this.forecastRevenueVnd,
    required this.demandRevenueVnd,
    required this.capacityRevenueVnd,
    required this.servedUnits,
    required this.isCompleteMonth,
  });

  final DateTime month;
  final double forecastRevenueVnd;
  final double demandRevenueVnd;
  final double capacityRevenueVnd;
  final double servedUnits;
  final bool isCompleteMonth;
}

class ForecastGoalResult {
  const ForecastGoalResult({
    required this.targetVnd,
    required this.status,
    this.firstReachedMonth,
    this.maintainedForThreeMonths = false,
  });

  final double targetVnd;
  final ForecastGoalStatus status;
  final DateTime? firstReachedMonth;
  final bool maintainedForThreeMonths;
}

class ForecastRecommendation {
  const ForecastRecommendation({
    required this.kind,
    required this.currentValue,
    required this.proposedValue,
    required this.extraRevenueVnd,
    required this.extraServedUnits,
    required this.nextBottleneck,
  });

  final ForecastRecommendationKind kind;
  final double currentValue;
  final double proposedValue;
  final double extraRevenueVnd;
  final double extraServedUnits;
  final String nextBottleneck;
}

class RevenueForecastResult {
  const RevenueForecastResult({
    required this.businessType,
    required this.regression,
    required this.backtest,
    required this.trainingStart,
    required this.trainingEnd,
    required this.days,
    required this.months,
    required this.goals,
    required this.recommendations,
    required this.dineInShare,
    required this.usesEquivalentPhotoSessions,
  });

  final ForecastBusinessType businessType;
  final ForecastRegression regression;
  final ForecastBacktestMetrics backtest;
  final DateTime trainingStart;
  final DateTime trainingEnd;
  final List<ForecastDayResult> days;
  final List<ForecastMonthResult> months;
  final List<ForecastGoalResult> goals;
  final List<ForecastRecommendation> recommendations;
  final double dineInShare;
  final bool usesEquivalentPhotoSessions;

  double get totalForecastRevenueVnd =>
      months.fold(0, (sum, month) => sum + month.forecastRevenueVnd);
}

class RevenueForecastEngine {
  const RevenueForecastEngine();

  void validateRestaurantProfile(RestaurantForecastProfile profile) =>
      _validateRestaurantProfile(profile);

  void validatePhotoProfile(PhotoForecastProfile profile) =>
      _validatePhotoProfile(profile);

  RevenueForecastResult forecastRestaurant({
    required List<RevenueForecastObservation> observations,
    required DateTime trainingStart,
    required DateTime trainingEnd,
    required DateTime forecastEnd,
    required RestaurantForecastProfile profile,
    List<double> goalsVnd = const [1000000000, 1500000000],
  }) {
    _validateRestaurantProfile(profile);
    final normalized = _validateAndNormalizeObservations(
      observations,
      trainingStart,
      trainingEnd,
      operatingWeekdays: profile.operatingWeekdays,
    );
    final regression = _fitRegression(
      normalized.map((row) => row.revenueVnd).toList(growable: false),
      normalized.map((row) => row.date).toList(growable: false),
    );
    final backtest = _rollingOriginBacktest(
      normalized: normalized,
      values: normalized.map((row) => row.revenueVnd).toList(growable: false),
      operatingWeekdays: profile.operatingWeekdays,
    );
    final totalRevenue = normalized.fold<double>(
      0,
      (sum, row) => sum + row.revenueVnd,
    );
    final totalDineIn = normalized.fold<double>(
      0,
      (sum, row) => sum + row.dineInRevenueVnd,
    );
    final dineInShare = totalRevenue <= 0
        ? 1.0
        : (totalDineIn / totalRevenue).clamp(0.0, 1.0);
    final days = _restaurantDays(
      regression: regression,
      origin: normalized.first.date,
      trainingEnd: _dateOnly(trainingEnd),
      forecastEnd: _dateOnly(forecastEnd),
      profile: profile,
      dineInShare: dineInShare,
    );
    final months = _aggregateMonths(days);
    final goals = _resolveGoals(months, goalsVnd);
    final recommendations = _restaurantRecommendations(
      regression: regression,
      origin: normalized.first.date,
      trainingEnd: _dateOnly(trainingEnd),
      forecastEnd: _dateOnly(forecastEnd),
      baselineProfile: profile,
      dineInShare: dineInShare,
      baseline: days,
    );

    return RevenueForecastResult(
      businessType: ForecastBusinessType.restaurant,
      regression: regression,
      backtest: backtest,
      trainingStart: _dateOnly(trainingStart),
      trainingEnd: _dateOnly(trainingEnd),
      days: days,
      months: months,
      goals: goals,
      recommendations: recommendations,
      dineInShare: dineInShare,
      usesEquivalentPhotoSessions: false,
    );
  }

  RevenueForecastResult forecastPhoto({
    required List<RevenueForecastObservation> observations,
    required DateTime trainingStart,
    required DateTime trainingEnd,
    required DateTime forecastEnd,
    required PhotoForecastProfile profile,
    List<double> goalsVnd = const [1000000000, 1500000000],
  }) {
    _validatePhotoProfile(profile);
    final normalized = _validateAndNormalizeObservations(
      observations,
      trainingStart,
      trainingEnd,
      operatingWeekdays: profile.operatingWeekdays,
    );
    var usedEquivalentSessions = false;
    final sessions = normalized
        .map((row) {
          final explicit = row.units;
          if (explicit != null && explicit >= 0 && explicit.isFinite) {
            return explicit;
          }
          usedEquivalentSessions = true;
          return row.revenueVnd / photoRevenuePerPaidSessionVnd;
        })
        .toList(growable: false);
    final regression = _fitRegression(
      sessions,
      normalized.map((row) => row.date).toList(growable: false),
    );
    final backtest = _rollingOriginBacktest(
      normalized: normalized,
      values: sessions,
      operatingWeekdays: profile.operatingWeekdays,
    );
    final origin = normalized.first.date;
    final capacitySessions = math.max(
      0,
      profile.machineCount *
              (profile.operatingMinutesPerDay ~/ photoSessionMinutes) -
          profile.freeServiceSessionsPerDay,
    );
    final start = _dateOnly(trainingEnd).add(const Duration(days: 1));
    final end = _dateOnly(forecastEnd);
    if (end.isBefore(start)) {
      throw const ForecastValidationException('FORECAST_END_BEFORE_START');
    }
    final days = <ForecastDayResult>[];
    for (
      var date = start;
      !date.isAfter(end);
      date = date.add(const Duration(days: 1))
    ) {
      final demandSessions = regression.predict(date, origin);
      final isOpen = profile.operatingWeekdays.contains(date.weekday);
      final dailyCapacitySessions = isOpen ? capacitySessions : 0;
      final servedSessions = math.min(
        demandSessions,
        dailyCapacitySessions.toDouble(),
      );
      days.add(
        ForecastDayResult(
          date: date,
          demandUnits: demandSessions,
          servedUnits: servedSessions,
          demandRevenueVnd: demandSessions * photoRevenuePerPaidSessionVnd,
          forecastRevenueVnd: servedSessions * photoRevenuePerPaidSessionVnd,
          capacityRevenueVnd:
              dailyCapacitySessions * photoRevenuePerPaidSessionVnd,
          bottleneck: !isOpen
              ? 'closed'
              : demandSessions > dailyCapacitySessions
              ? 'photo_capacity'
              : 'demand',
        ),
      );
    }
    final months = _aggregateMonths(days);
    return RevenueForecastResult(
      businessType: ForecastBusinessType.photo,
      regression: regression,
      backtest: backtest,
      trainingStart: _dateOnly(trainingStart),
      trainingEnd: _dateOnly(trainingEnd),
      days: days,
      months: months,
      goals: _resolveGoals(months, goalsVnd),
      recommendations: const [],
      dineInShare: 0,
      usesEquivalentPhotoSessions: usedEquivalentSessions,
    );
  }
}

List<RevenueForecastObservation> _validateAndNormalizeObservations(
  List<RevenueForecastObservation> observations,
  DateTime trainingStart,
  DateTime trainingEnd, {
  required Set<int> operatingWeekdays,
}) {
  final start = _dateOnly(trainingStart);
  final end = _dateOnly(trainingEnd);
  if (end.isBefore(start)) {
    throw const ForecastValidationException('TRAINING_RANGE_INVALID');
  }
  final expectedDays = end.difference(start).inDays + 1;
  if (expectedDays < minimumForecastTrainingDays) {
    throw const ForecastValidationException('TRAINING_PERIOD_TOO_SHORT');
  }
  final byDay = <DateTime, RevenueForecastObservation>{};
  for (final row in observations) {
    final date = _dateOnly(row.date);
    if (date.isBefore(start) || date.isAfter(end)) continue;
    if (!row.revenueVnd.isFinite || row.revenueVnd < 0) {
      throw const ForecastValidationException('INVALID_REVENUE');
    }
    if (!row.dineInRevenueVnd.isFinite ||
        row.dineInRevenueVnd < 0 ||
        row.dineInRevenueVnd > row.revenueVnd) {
      throw const ForecastValidationException('INVALID_DINE_IN_REVENUE');
    }
    if (row.units != null && (!row.units!.isFinite || row.units! < 0)) {
      throw const ForecastValidationException('INVALID_UNITS');
    }
    if (byDay.containsKey(date)) {
      throw const ForecastValidationException('DUPLICATE_TRAINING_DAY');
    }
    byDay[date] = RevenueForecastObservation(
      date: date,
      revenueVnd: row.revenueVnd,
      dineInRevenueVnd: row.dineInRevenueVnd,
      units: row.units,
    );
  }
  for (
    var date = start;
    !date.isAfter(end);
    date = date.add(const Duration(days: 1))
  ) {
    final observation = byDay[date];
    final isOpen = operatingWeekdays.contains(date.weekday);
    if (observation == null) {
      if (isOpen) {
        throw const ForecastValidationException('TRAINING_DAYS_INCOMPLETE');
      }
      byDay[date] = RevenueForecastObservation(
        date: date,
        revenueVnd: 0,
        units: 0,
      );
    } else if (!isOpen) {
      if (observation.revenueVnd > 0 || (observation.units ?? 0) > 0) {
        throw const ForecastValidationException('CLOSED_DAY_HAS_REVENUE');
      }
      byDay[date] = RevenueForecastObservation(
        date: date,
        revenueVnd: 0,
        units: 0,
      );
    }
  }
  final operatingDayCount = byDay.values
      .where((row) => operatingWeekdays.contains(row.date.weekday))
      .length;
  if (operatingDayCount < minimumForecastTrainingDays) {
    throw const ForecastValidationException('TRAINING_PERIOD_TOO_SHORT');
  }
  final normalized = byDay.values.toList(growable: false)
    ..sort((a, b) => a.date.compareTo(b.date));
  if (normalized.every((row) => row.revenueVnd == 0)) {
    throw const ForecastValidationException('NO_REVENUE_SIGNAL');
  }
  return normalized;
}

ForecastRegression _fitRegression(List<double> values, List<DateTime> dates) {
  if (values.length != dates.length ||
      values.length < minimumForecastTrainingDays) {
    throw const ForecastValidationException('TRAINING_PERIOD_TOO_SHORT');
  }
  final origin = _dateOnly(dates.first);
  final dayIndexes = dates
      .map((date) => _dateOnly(date).difference(origin).inDays.toDouble())
      .toList(growable: false);
  final centerDay = dayIndexes.reduce((a, b) => a + b) / dayIndexes.length;
  final x = <List<double>>[
    for (var i = 0; i < dates.length; i++)
      _predictors(dayIndexes[i], centerDay, dates[i].weekday),
  ];
  final coefficients = _leastSquares(x, values);
  final fitted = <double>[];
  for (final row in x) {
    var value = 0.0;
    for (var i = 0; i < coefficients.length; i++) {
      value += row[i] * coefficients[i];
    }
    fitted.add(value);
  }
  final mean = values.reduce((a, b) => a + b) / values.length;
  var squaredError = 0.0;
  var totalSquared = 0.0;
  for (var i = 0; i < values.length; i++) {
    squaredError += math.pow(values[i] - fitted[i], 2).toDouble();
    totalSquared += math.pow(values[i] - mean, 2).toDouble();
  }
  final degreesOfFreedom = math.max(1, values.length - coefficients.length);
  return ForecastRegression(
    coefficients: List.unmodifiable(coefficients),
    centerDay: centerDay,
    rmse: math.sqrt(squaredError / degreesOfFreedom),
    rSquared: totalSquared == 0 ? 0 : 1 - squaredError / totalSquared,
  );
}

ForecastBacktestMetrics _rollingOriginBacktest({
  required List<RevenueForecastObservation> normalized,
  required List<double> values,
  required Set<int> operatingWeekdays,
}) {
  final absoluteErrors = <double>[];
  final squaredErrors = <double>[];
  final signedErrors = <double>[];
  final baselineAbsoluteErrors = <double>[];
  var actualTotal = 0.0;
  var operatingDaysSeen = 0;

  for (var targetIndex = 0; targetIndex < normalized.length; targetIndex++) {
    final target = normalized[targetIndex];
    if (!operatingWeekdays.contains(target.date.weekday)) continue;
    if (operatingDaysSeen < minimumForecastTrainingDays) {
      operatingDaysSeen += 1;
      continue;
    }
    final trainingRows = normalized.sublist(0, targetIndex);
    final trainingValues = values.sublist(0, targetIndex);
    ForecastRegression regression;
    try {
      regression = _fitRegression(
        trainingValues,
        trainingRows.map((row) => row.date).toList(growable: false),
      );
    } on ForecastValidationException {
      operatingDaysSeen += 1;
      continue;
    }
    final predicted = regression.predict(target.date, trainingRows.first.date);
    final actual = values[targetIndex];
    final error = predicted - actual;
    absoluteErrors.add(error.abs());
    squaredErrors.add(error * error);
    signedErrors.add(error);
    actualTotal += actual.abs();

    final sameWeekdayValues = <double>[
      for (var index = 0; index < targetIndex; index++)
        if (normalized[index].date.weekday == target.date.weekday &&
            operatingWeekdays.contains(normalized[index].date.weekday))
          values[index],
    ];
    final baselineSource = sameWeekdayValues.isNotEmpty
        ? sameWeekdayValues
        : <double>[
            for (var index = 0; index < targetIndex; index++)
              if (operatingWeekdays.contains(normalized[index].date.weekday))
                values[index],
          ];
    if (baselineSource.isNotEmpty) {
      final baseline =
          baselineSource.reduce((a, b) => a + b) / baselineSource.length;
      baselineAbsoluteErrors.add((baseline - actual).abs());
    }
    operatingDaysSeen += 1;
  }

  if (absoluteErrors.isEmpty) {
    return const ForecastBacktestMetrics(foldCount: 0);
  }
  final count = absoluteErrors.length;
  return ForecastBacktestMetrics(
    foldCount: count,
    mae: absoluteErrors.reduce((a, b) => a + b) / count,
    rmse: math.sqrt(squaredErrors.reduce((a, b) => a + b) / count),
    wape: actualTotal > 0
        ? absoluteErrors.reduce((a, b) => a + b) / actualTotal
        : null,
    bias: signedErrors.reduce((a, b) => a + b) / count,
    weekdayBaselineMae: baselineAbsoluteErrors.isEmpty
        ? null
        : baselineAbsoluteErrors.reduce((a, b) => a + b) /
              baselineAbsoluteErrors.length,
  );
}

List<double> _predictors(double day, double centerDay, int weekday) => [
  1,
  day - centerDay,
  for (
    var candidate = DateTime.tuesday;
    candidate <= DateTime.sunday;
    candidate++
  )
    weekday == candidate ? 1 : 0,
];

List<double> _leastSquares(List<List<double>> x, List<double> y) {
  final columns = x.first.length;
  final augmented = List.generate(
    columns,
    (row) => List<double>.filled(columns + 1, 0),
  );
  for (var row = 0; row < columns; row++) {
    for (var column = 0; column < columns; column++) {
      for (var sample = 0; sample < x.length; sample++) {
        augmented[row][column] += x[sample][row] * x[sample][column];
      }
    }
    for (var sample = 0; sample < x.length; sample++) {
      augmented[row][columns] += x[sample][row] * y[sample];
    }
  }
  for (var pivot = 0; pivot < columns; pivot++) {
    var best = pivot;
    for (var row = pivot + 1; row < columns; row++) {
      if (augmented[row][pivot].abs() > augmented[best][pivot].abs()) {
        best = row;
      }
    }
    if (augmented[best][pivot].abs() < 1e-9) {
      throw const ForecastValidationException('REGRESSION_SINGULAR');
    }
    final swap = augmented[pivot];
    augmented[pivot] = augmented[best];
    augmented[best] = swap;
    final divisor = augmented[pivot][pivot];
    for (var column = pivot; column <= columns; column++) {
      augmented[pivot][column] /= divisor;
    }
    for (var row = 0; row < columns; row++) {
      if (row == pivot) continue;
      final factor = augmented[row][pivot];
      for (var column = pivot; column <= columns; column++) {
        augmented[row][column] -= factor * augmented[pivot][column];
      }
    }
  }
  return [for (var row = 0; row < columns; row++) augmented[row][columns]];
}

List<ForecastDayResult> _restaurantDays({
  required ForecastRegression regression,
  required DateTime origin,
  required DateTime trainingEnd,
  required DateTime forecastEnd,
  required RestaurantForecastProfile profile,
  required double dineInShare,
}) {
  final start = trainingEnd.add(const Duration(days: 1));
  if (forecastEnd.isBefore(start)) {
    throw const ForecastValidationException('FORECAST_END_BEFORE_START');
  }
  final hours = profile.operatingMinutesPerDay / 60;
  final tableCount = profile.floors.fold<int>(
    0,
    (sum, floor) => sum + floor.tableCount,
  );
  final tableCapacity =
      tableCount * profile.operatingMinutesPerDay / profile.tableCycleMinutes;
  final floorCapacity = profile.floors.fold<double>(
    0,
    (sum, floor) => sum + floor.serviceUnitsPerHour * hours,
  );
  final dineInCapacity = math.min(tableCapacity, floorCapacity);
  final kitchenCapacity = profile.kitchenUnitsPerHour * hours;
  final checkerCapacity = profile.checkerUnitsPerHour * hours;
  final sharedCapacity = math.min(kitchenCapacity, checkerCapacity);
  final mixCapacity = dineInShare <= 0
      ? sharedCapacity
      : math.min(sharedCapacity, dineInCapacity / dineInShare);
  final bottleneck = _restaurantBottleneck(
    tableCapacity: tableCapacity,
    floorCapacity: floorCapacity,
    kitchenCapacity: kitchenCapacity,
    checkerCapacity: checkerCapacity,
    dineInShare: dineInShare,
  );
  final result = <ForecastDayResult>[];
  for (
    var date = start;
    !date.isAfter(forecastEnd);
    date = date.add(const Duration(days: 1))
  ) {
    final demandRevenue = regression.predict(date, origin);
    final demandUnits = demandRevenue / profile.averageTicketVnd;
    final isOpen = profile.operatingWeekdays.contains(date.weekday);
    final dailyMixCapacity = isOpen ? mixCapacity : 0.0;
    final servedUnits = math.min(demandUnits, dailyMixCapacity);
    result.add(
      ForecastDayResult(
        date: date,
        demandUnits: demandUnits,
        servedUnits: servedUnits,
        demandRevenueVnd: demandRevenue,
        forecastRevenueVnd: servedUnits * profile.averageTicketVnd,
        capacityRevenueVnd: dailyMixCapacity * profile.averageTicketVnd,
        bottleneck: !isOpen
            ? 'closed'
            : demandUnits > dailyMixCapacity
            ? bottleneck
            : 'demand',
      ),
    );
  }
  return result;
}

String _restaurantBottleneck({
  required double tableCapacity,
  required double floorCapacity,
  required double kitchenCapacity,
  required double checkerCapacity,
  required double dineInShare,
}) {
  final capacities = <String, double>{
    'kitchen': kitchenCapacity,
    'checker': checkerCapacity,
    if (dineInShare > 0) 'table_turnover': tableCapacity / dineInShare,
    if (dineInShare > 0) 'floor_service': floorCapacity / dineInShare,
  };
  return capacities.entries.reduce((a, b) => a.value <= b.value ? a : b).key;
}

List<ForecastMonthResult> _aggregateMonths(List<ForecastDayResult> days) {
  final groups = <DateTime, List<ForecastDayResult>>{};
  for (final day in days) {
    final month = DateTime.utc(day.date.year, day.date.month);
    groups.putIfAbsent(month, () => <ForecastDayResult>[]).add(day);
  }
  return groups.entries
      .map((entry) {
        final rows = entry.value;
        final monthStart = entry.key;
        final monthEnd = DateTime.utc(
          monthStart.year,
          monthStart.month + 1,
        ).subtract(const Duration(days: 1));
        return ForecastMonthResult(
          month: monthStart,
          forecastRevenueVnd: rows.fold(
            0,
            (sum, row) => sum + row.forecastRevenueVnd,
          ),
          demandRevenueVnd: rows.fold(
            0,
            (sum, row) => sum + row.demandRevenueVnd,
          ),
          capacityRevenueVnd: rows.fold(
            0,
            (sum, row) => sum + row.capacityRevenueVnd,
          ),
          servedUnits: rows.fold(0, (sum, row) => sum + row.servedUnits),
          isCompleteMonth:
              rows.first.date.day == 1 && rows.last.date.day == monthEnd.day,
        );
      })
      .toList(growable: false)
    ..sort((a, b) => a.month.compareTo(b.month));
}

List<ForecastGoalResult> _resolveGoals(
  List<ForecastMonthResult> months,
  List<double> goals,
) => goals
    .map((target) {
      final complete = months.where((month) => month.isCompleteMonth).toList();
      for (var i = 0; i < complete.length; i++) {
        if (complete[i].forecastRevenueVnd < target) continue;
        final maintained =
            i + 2 < complete.length &&
            complete
                .sublist(i, i + 3)
                .every((month) => month.forecastRevenueVnd >= target);
        return ForecastGoalResult(
          targetVnd: target,
          status: ForecastGoalStatus.reached,
          firstReachedMonth: complete[i].month,
          maintainedForThreeMonths: maintained,
        );
      }
      final maximumCapacity = complete.isEmpty
          ? 0.0
          : complete.map((month) => month.capacityRevenueVnd).reduce(math.max);
      return ForecastGoalResult(
        targetVnd: target,
        status: maximumCapacity < target
            ? ForecastGoalStatus.capacityExceeded
            : ForecastGoalStatus.demandNotReached,
      );
    })
    .toList(growable: false);

List<ForecastRecommendation> _restaurantRecommendations({
  required ForecastRegression regression,
  required DateTime origin,
  required DateTime trainingEnd,
  required DateTime forecastEnd,
  required RestaurantForecastProfile baselineProfile,
  required double dineInShare,
  required List<ForecastDayResult> baseline,
}) {
  final baselineRevenue = baseline.fold<double>(
    0,
    (sum, day) => sum + day.forecastRevenueVnd,
  );
  final baselineUnits = baseline.fold<double>(
    0,
    (sum, day) => sum + day.servedUnits,
  );
  final candidates =
      <(ForecastRecommendationKind, double, double, RestaurantForecastProfile)>[
        (
          ForecastRecommendationKind.tableTurnover,
          baselineProfile.cleanupMinutes,
          baselineProfile.cleanupMinutes * 0.8,
          baselineProfile.copyWith(
            cleanupMinutes: baselineProfile.cleanupMinutes * 0.8,
          ),
        ),
        (
          ForecastRecommendationKind.kitchen,
          baselineProfile.kitchenUnitsPerHour,
          baselineProfile.kitchenUnitsPerHour * 1.1,
          baselineProfile.copyWith(
            kitchenUnitsPerHour: baselineProfile.kitchenUnitsPerHour * 1.1,
          ),
        ),
        (
          ForecastRecommendationKind.checker,
          baselineProfile.checkerUnitsPerHour,
          baselineProfile.checkerUnitsPerHour * 1.1,
          baselineProfile.copyWith(
            checkerUnitsPerHour: baselineProfile.checkerUnitsPerHour * 1.1,
          ),
        ),
        (
          ForecastRecommendationKind.floorService,
          baselineProfile.floors.fold<double>(
            0,
            (sum, floor) => sum + floor.serviceUnitsPerHour,
          ),
          baselineProfile.floors.fold<double>(
                0,
                (sum, floor) => sum + floor.serviceUnitsPerHour,
              ) *
              1.1,
          baselineProfile.copyWith(
            floors: baselineProfile.floors
                .map(
                  (floor) => floor.copyWith(
                    serviceUnitsPerHour: floor.serviceUnitsPerHour * 1.1,
                  ),
                )
                .toList(growable: false),
          ),
        ),
        (
          ForecastRecommendationKind.nonDiningWait,
          baselineProfile.paymentWaitMinutes,
          baselineProfile.paymentWaitMinutes * 0.8,
          baselineProfile.copyWith(
            paymentWaitMinutes: baselineProfile.paymentWaitMinutes * 0.8,
          ),
        ),
        (
          ForecastRecommendationKind.operatingHours,
          baselineProfile.operatingMinutesPerDay.toDouble(),
          baselineProfile.operatingMinutesPerDay + 60.0,
          baselineProfile.copyWith(
            operatingMinutesPerDay: baselineProfile.operatingMinutesPerDay + 60,
          ),
        ),
      ];
  final recommendations = <ForecastRecommendation>[];
  for (final candidate in candidates) {
    final rerun = _restaurantDays(
      regression: regression,
      origin: origin,
      trainingEnd: trainingEnd,
      forecastEnd: forecastEnd,
      profile: candidate.$4,
      dineInShare: dineInShare,
    );
    final revenue = rerun.fold<double>(
      0,
      (sum, day) => sum + day.forecastRevenueVnd,
    );
    final units = rerun.fold<double>(0, (sum, day) => sum + day.servedUnits);
    final constrained = rerun.where(
      (day) => day.bottleneck != 'demand' && day.bottleneck != 'closed',
    );
    final nextBottleneck = constrained.isEmpty
        ? 'demand'
        : constrained
              .map((day) => day.bottleneck)
              .fold<Map<String, int>>({}, (counts, value) {
                counts[value] = (counts[value] ?? 0) + 1;
                return counts;
              })
              .entries
              .reduce((a, b) => a.value >= b.value ? a : b)
              .key;
    recommendations.add(
      ForecastRecommendation(
        kind: candidate.$1,
        currentValue: candidate.$2,
        proposedValue: candidate.$3,
        extraRevenueVnd: math.max(0, revenue - baselineRevenue),
        extraServedUnits: math.max(0, units - baselineUnits),
        nextBottleneck: nextBottleneck,
      ),
    );
  }
  recommendations.sort(
    (a, b) => b.extraRevenueVnd.compareTo(a.extraRevenueVnd),
  );
  return List.unmodifiable(recommendations);
}

void _validateRestaurantProfile(RestaurantForecastProfile profile) {
  if (profile.floors.isEmpty ||
      profile.floors.any(
        (floor) =>
            floor.label.trim().isEmpty ||
            floor.tableCount <= 0 ||
            !floor.serviceUnitsPerHour.isFinite ||
            floor.serviceUnitsPerHour <= 0,
      ) ||
      !profile.seatedToFirstServeMinutes.isFinite ||
      profile.seatedToFirstServeMinutes < 0 ||
      !profile.diningMinutes.isFinite ||
      profile.diningMinutes <= 0 ||
      !profile.paymentWaitMinutes.isFinite ||
      profile.paymentWaitMinutes < 0 ||
      !profile.cleanupMinutes.isFinite ||
      profile.cleanupMinutes < 0 ||
      !profile.tableCycleMinutes.isFinite ||
      profile.tableCycleMinutes <= 0 ||
      !profile.kitchenUnitsPerHour.isFinite ||
      profile.kitchenUnitsPerHour <= 0 ||
      !profile.checkerUnitsPerHour.isFinite ||
      profile.checkerUnitsPerHour <= 0 ||
      profile.operatingMinutesPerDay <= 0 ||
      profile.operatingMinutesPerDay > 1440 ||
      profile.operatingWeekdays.isEmpty ||
      profile.operatingWeekdays.any((weekday) => weekday < 1 || weekday > 7) ||
      !profile.averageTicketVnd.isFinite ||
      profile.averageTicketVnd <= 0) {
    throw const ForecastValidationException('RESTAURANT_PROFILE_INVALID');
  }
}

void _validatePhotoProfile(PhotoForecastProfile profile) {
  if (profile.machineCount <= 0 ||
      profile.operatingMinutesPerDay <= 0 ||
      profile.operatingMinutesPerDay > 1440 ||
      profile.operatingWeekdays.isEmpty ||
      profile.operatingWeekdays.any((weekday) => weekday < 1 || weekday > 7) ||
      profile.freeServiceSessionsPerDay < 0) {
    throw const ForecastValidationException('PHOTO_PROFILE_INVALID');
  }
  final totalCapacity =
      profile.machineCount *
      (profile.operatingMinutesPerDay ~/ photoSessionMinutes);
  if (profile.freeServiceSessionsPerDay > totalCapacity) {
    throw const ForecastValidationException('PHOTO_SERVICE_EXCEEDS_CAPACITY');
  }
}

DateTime _dateOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);
