import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/utils/floor_label.dart';
import 'revenue_forecast_engine.dart';

enum RevenueForecastInputField {
  floorLabel,
  tableCount,
  floorServiceRate,
  firstServeMinutes,
  diningMinutes,
  paymentWaitMinutes,
  cleanupMinutes,
  kitchenRate,
  checkerRate,
  operatingMinutes,
  averageTicket,
}

enum RevenueForecastInputSource {
  selectedPeriodAverage,
  registeredConfiguration,
  savedProfile,
  manualAssumption,
  unavailable,
}

class RevenueForecastInputEvidence {
  const RevenueForecastInputEvidence({
    required this.source,
    this.sampleCount = 0,
    this.observedDays = 0,
    this.isProxy = false,
  });

  final RevenueForecastInputSource source;
  final int sampleCount;
  final int observedDays;
  final bool isProxy;

  Map<String, dynamic> toJson() => {
    'source': source.name,
    'sample_count': sampleCount,
    'observed_days': observedDays,
    'is_proxy': isProxy,
  };
}

class RevenueForecastOperationalDefaults {
  const RevenueForecastOperationalDefaults({
    required this.profile,
    required this.usesMeasuredOperations,
    required this.usesFallbackAssumptions,
    this.evidence = const {},
    this.periodStart,
    this.periodEnd,
  });

  final RestaurantForecastProfile profile;
  final bool usesMeasuredOperations;
  // Kept for serialized/test compatibility. New defaults never inject fallback
  // numbers: unavailable inputs stay blank until a manager enters a value.
  final bool usesFallbackAssumptions;
  final Map<RevenueForecastInputField, RevenueForecastInputEvidence> evidence;
  final DateTime? periodStart;
  final DateTime? periodEnd;

  bool get hasUnavailableInputs => evidence.values.any(
    (item) => item.source == RevenueForecastInputSource.unavailable,
  );

  RevenueForecastInputEvidence evidenceFor(RevenueForecastInputField field) =>
      evidence[field] ??
      const RevenueForecastInputEvidence(
        source: RevenueForecastInputSource.unavailable,
      );
}

abstract interface class RevenueForecastDefaultsRepository {
  Future<RevenueForecastOperationalDefaults?> loadRestaurant({
    required String storeId,
    required DateTime trainingStart,
    required DateTime trainingEnd,
    required List<RevenueForecastObservation> observations,
  });
}

class RevenueForecastDefaultsService
    implements RevenueForecastDefaultsRepository {
  RevenueForecastDefaultsService(this._client);

  final SupabaseClient _client;

  @override
  Future<RevenueForecastOperationalDefaults?> loadRestaurant({
    required String storeId,
    required DateTime trainingStart,
    required DateTime trainingEnd,
    required List<RevenueForecastObservation> observations,
  }) async {
    final tables = await _loadTables(storeId);
    if (tables.isEmpty) return null;

    Map<String, dynamic> operations = const {};
    final periodStart = _dateOnly(trainingStart);
    final requestedEnd = _dateOnly(trainingEnd);
    final lastCompletedDay = _lastCompletedHoChiMinhDay();
    final periodEnd = requestedEnd.isBefore(lastCompletedDay)
        ? requestedEnd
        : lastCompletedDay;
    if (!periodEnd.isBefore(periodStart)) {
      try {
        final range = _reportUtcRange(periodStart, periodEnd);
        final params = {
          'p_store_id': storeId,
          'p_from': range.startUtc.toIso8601String(),
          'p_to': range.endExclusiveUtc.toIso8601String(),
        };
        dynamic response;
        try {
          response = await _client.rpc(
            'get_revenue_forecast_operating_averages',
            params: params,
          );
        } catch (_) {
          // Supports a rolling deployment. The legacy report has the same
          // authorization boundary; fields it cannot measure remain unavailable.
          response = await _client.rpc(
            'get_paperless_operations_insights_report',
            params: params,
          );
        }
        if (response is Map) {
          operations = Map<String, dynamic>.from(response);
        }
      } catch (_) {
        // Registered table configuration is still useful. We deliberately do
        // not replace missing measurements with invented constants.
      }
    }

    final completedObservations = observations
        .where((row) {
          final date = _dateOnly(row.date);
          return !date.isBefore(periodStart) && !date.isAfter(periodEnd);
        })
        .toList(growable: false);

    return deriveRestaurantForecastDefaults(
      tables: tables,
      operations: operations,
      observations: completedObservations,
      periodStart: periodStart,
      periodEnd: periodEnd,
    );
  }

  Future<List<Map<String, dynamic>>> _loadTables(String storeId) async {
    try {
      final response = await _client
          .from('tables')
          .select('id, floor_label')
          .eq('restaurant_id', storeId);
      return response
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false);
    } catch (error) {
      final message = error.toString().toLowerCase();
      if (!message.contains('floor_label')) rethrow;
      final response = await _client
          .from('tables')
          .select('id')
          .eq('restaurant_id', storeId);
      return response
          .whereType<Map>()
          .map((row) => <String, dynamic>{...row, 'floor_label': '1F'})
          .toList(growable: false);
    }
  }
}

RevenueForecastOperationalDefaults? deriveRestaurantForecastDefaults({
  required List<Map<String, dynamic>> tables,
  required Map<String, dynamic> operations,
  required List<RevenueForecastObservation> observations,
  DateTime? periodStart,
  DateTime? periodEnd,
}) {
  final tableCounts = <String, int>{};
  for (final table in tables) {
    final rawLabel = table['floor_label']?.toString().trim() ?? '';
    final label = rawLabel.isEmpty ? '1F' : rawLabel.toUpperCase();
    tableCounts.update(label, (count) => count + 1, ifAbsent: () => 1);
  }
  if (tableCounts.isEmpty) return null;

  final floorLabels = tableCounts.keys.toList(growable: false)
    ..sort(_compareFloorLabels);
  final totalTables = tableCounts.values.fold<int>(
    0,
    (sum, value) => sum + value,
  );

  final measuredFirstServeSeconds = _positiveNumber(
    operations['average_first_serve_seconds'],
  );
  final measuredDiningSeconds = _positiveNumber(
    operations['average_dining_seconds'],
  );
  final firstServeMinutes = measuredFirstServeSeconds == null
      ? 0.0
      : _roundTwoDecimals(measuredFirstServeSeconds / 60);
  final diningMinutes = measuredDiningSeconds == null
      ? 0.0
      : _roundTwoDecimals(measuredDiningSeconds / 60);
  const paymentWaitMinutes = 0.0;
  const cleanupMinutes = 0.0;

  final forecastHourlyRows = _maps(operations['forecast_hourly_orders']);
  final hourlyRows = forecastHourlyRows.isNotEmpty
      ? forecastHourlyRows
      : _maps(operations['hourly_orders']);
  final activeHourlyRows = hourlyRows
      .where((row) => _number(row['order_count']) > 0)
      .toList(growable: false);
  final totalCompleted = activeHourlyRows.fold<double>(
    0,
    (sum, row) => sum + math.max(0, _number(row['completed_count'])),
  );
  final kitchenRate = activeHourlyRows.isEmpty || totalCompleted <= 0
      ? 0.0
      : _roundTwoDecimals(totalCompleted / activeHourlyRows.length);
  final checkerRate = activeHourlyRows.isEmpty || totalCompleted <= 0
      ? 0.0
      : _roundTwoDecimals(totalCompleted / activeHourlyRows.length);
  final floorTotalRate = checkerRate;
  final operatingStats = _averageOperatingMinutes(activeHourlyRows);
  final operatingMinutes = operatingStats?.minutes ?? 0;

  final floors = <RestaurantFloorCapacity>[
    for (final label in floorLabels)
      RestaurantFloorCapacity(
        label: displayFloorLabel(label),
        tableCount: tableCounts[label]!,
        serviceUnitsPerHour: math.max(
          0,
          floorTotalRate * tableCounts[label]! / totalTables,
        ),
      ),
  ];

  final operatingWeekdays = <int>{
    for (final row in observations)
      if (row.revenueVnd > 0 || row.dineInRevenueVnd > 0) row.date.weekday,
  };
  if (operatingWeekdays.isEmpty) {
    operatingWeekdays.addAll(_weekdaysFromHourlyRows(activeHourlyRows));
  }

  final ticketRows = observations.where(
    (row) =>
        (row.units ?? 0) > 0 &&
        row.dineInRevenueVnd.isFinite &&
        row.dineInRevenueVnd > 0,
  );
  final observedUnits = ticketRows.fold<double>(
    0,
    (sum, row) => sum + row.units!,
  );
  final dineInRevenue = ticketRows.fold<double>(
    0,
    (sum, row) => sum + row.dineInRevenueVnd,
  );
  final averageTicket = observedUnits > 0 && dineInRevenue > 0
      ? dineInRevenue / observedUnits
      : 0.0;

  final firstServeSamples = _nonNegativeInt(
    operations['first_serve_sample_count'],
  );
  final diningSamples = _nonNegativeInt(operations['dining_order_count']);
  final evidence = <RevenueForecastInputField, RevenueForecastInputEvidence>{
    RevenueForecastInputField.floorLabel: const RevenueForecastInputEvidence(
      source: RevenueForecastInputSource.registeredConfiguration,
    ),
    RevenueForecastInputField.tableCount: const RevenueForecastInputEvidence(
      source: RevenueForecastInputSource.registeredConfiguration,
    ),
    RevenueForecastInputField.floorServiceRate: RevenueForecastInputEvidence(
      source: checkerRate > 0
          ? RevenueForecastInputSource.selectedPeriodAverage
          : RevenueForecastInputSource.unavailable,
      sampleCount: totalCompleted.round(),
      observedDays: operatingStats?.dayCount ?? 0,
    ),
    RevenueForecastInputField.firstServeMinutes: RevenueForecastInputEvidence(
      source: measuredFirstServeSeconds != null && firstServeSamples > 0
          ? RevenueForecastInputSource.selectedPeriodAverage
          : RevenueForecastInputSource.unavailable,
      sampleCount: firstServeSamples,
      observedDays: operatingStats?.dayCount ?? 0,
      isProxy: measuredFirstServeSeconds != null && firstServeSamples > 0,
    ),
    RevenueForecastInputField.diningMinutes: RevenueForecastInputEvidence(
      source: measuredDiningSeconds != null && diningSamples > 0
          ? RevenueForecastInputSource.selectedPeriodAverage
          : RevenueForecastInputSource.unavailable,
      sampleCount: diningSamples,
      observedDays: operatingStats?.dayCount ?? 0,
    ),
    RevenueForecastInputField.paymentWaitMinutes:
        const RevenueForecastInputEvidence(
          source: RevenueForecastInputSource.unavailable,
        ),
    RevenueForecastInputField.cleanupMinutes:
        const RevenueForecastInputEvidence(
          source: RevenueForecastInputSource.unavailable,
        ),
    RevenueForecastInputField.kitchenRate: RevenueForecastInputEvidence(
      source: kitchenRate > 0
          ? RevenueForecastInputSource.selectedPeriodAverage
          : RevenueForecastInputSource.unavailable,
      sampleCount: totalCompleted.round(),
      observedDays: operatingStats?.dayCount ?? 0,
      isProxy: kitchenRate > 0,
    ),
    RevenueForecastInputField.checkerRate: RevenueForecastInputEvidence(
      source: checkerRate > 0
          ? RevenueForecastInputSource.selectedPeriodAverage
          : RevenueForecastInputSource.unavailable,
      sampleCount: totalCompleted.round(),
      observedDays: operatingStats?.dayCount ?? 0,
      isProxy: checkerRate > 0,
    ),
    RevenueForecastInputField.operatingMinutes: RevenueForecastInputEvidence(
      source: operatingStats == null
          ? RevenueForecastInputSource.unavailable
          : RevenueForecastInputSource.selectedPeriodAverage,
      observedDays: operatingStats?.dayCount ?? 0,
      isProxy: operatingStats != null,
    ),
    RevenueForecastInputField.averageTicket: RevenueForecastInputEvidence(
      source: averageTicket > 0
          ? RevenueForecastInputSource.selectedPeriodAverage
          : RevenueForecastInputSource.unavailable,
      sampleCount: ticketRows.length,
      observedDays: ticketRows.length,
    ),
  };

  final usesMeasuredOperations = evidence.values.any(
    (item) => item.source == RevenueForecastInputSource.selectedPeriodAverage,
  );

  return RevenueForecastOperationalDefaults(
    profile: RestaurantForecastProfile(
      floors: floors,
      seatedToFirstServeMinutes: firstServeMinutes,
      diningMinutes: diningMinutes,
      paymentWaitMinutes: paymentWaitMinutes,
      cleanupMinutes: cleanupMinutes,
      kitchenUnitsPerHour: kitchenRate,
      checkerUnitsPerHour: checkerRate,
      operatingMinutesPerDay: operatingMinutes,
      operatingWeekdays: operatingWeekdays,
      averageTicketVnd: _roundVnd(averageTicket),
    ),
    usesMeasuredOperations: usesMeasuredOperations,
    usesFallbackAssumptions: false,
    evidence: Map.unmodifiable(evidence),
    periodStart: periodStart,
    periodEnd: periodEnd,
  );
}

DateTime _dateOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

DateTime _lastCompletedHoChiMinhDay() {
  final localNow = DateTime.now().toUtc().add(const Duration(hours: 7));
  return DateTime.utc(
    localNow.year,
    localNow.month,
    localNow.day,
  ).subtract(const Duration(days: 1));
}

({DateTime startUtc, DateTime endExclusiveUtc}) _reportUtcRange(
  DateTime start,
  DateTime end,
) {
  const offset = Duration(hours: 7);
  return (
    startUtc: DateTime.utc(start.year, start.month, start.day).subtract(offset),
    endExclusiveUtc: DateTime.utc(
      end.year,
      end.month,
      end.day + 1,
    ).subtract(offset),
  );
}

({int minutes, int dayCount})? _averageOperatingMinutes(
  List<Map<String, dynamic>> hourlyRows,
) {
  final hoursByDay = <String, List<int>>{};
  final hourPattern = RegExp(r'^(\d{4}-\d{2}-\d{2})T(\d{2})');
  for (final row in hourlyRows) {
    final match = hourPattern.firstMatch(row['hour']?.toString() ?? '');
    if (match == null || _number(row['order_count']) <= 0) continue;
    final hour = int.tryParse(match.group(2)!);
    if (hour == null || hour < 0 || hour > 23) continue;
    hoursByDay.putIfAbsent(match.group(1)!, () => <int>[]).add(hour);
  }
  if (hoursByDay.isEmpty) return null;
  var totalMinutes = 0;
  for (final hours in hoursByDay.values) {
    final first = hours.reduce(math.min);
    final last = hours.reduce(math.max);
    totalMinutes += (last - first + 1) * 60;
  }
  return (
    minutes: (totalMinutes / hoursByDay.length).round().clamp(60, 1440).toInt(),
    dayCount: hoursByDay.length,
  );
}

Set<int> _weekdaysFromHourlyRows(List<Map<String, dynamic>> hourlyRows) {
  final weekdays = <int>{};
  final datePattern = RegExp(r'^(\d{4})-(\d{2})-(\d{2})T');
  for (final row in hourlyRows) {
    final match = datePattern.firstMatch(row['hour']?.toString() ?? '');
    if (match == null) continue;
    final date = DateTime.tryParse(
      '${match.group(1)}-${match.group(2)}-${match.group(3)}',
    );
    if (date != null) weekdays.add(date.weekday);
  }
  return weekdays;
}

int _compareFloorLabels(String left, String right) {
  final numberPattern = RegExp(r'\d+');
  final leftNumber = int.tryParse(
    numberPattern.firstMatch(left)?.group(0) ?? '',
  );
  final rightNumber = int.tryParse(
    numberPattern.firstMatch(right)?.group(0) ?? '',
  );
  if (leftNumber != null && rightNumber != null && leftNumber != rightNumber) {
    return leftNumber.compareTo(rightNumber);
  }
  return left.compareTo(right);
}

List<Map<String, dynamic>> _maps(dynamic value) {
  if (value is! List) return const [];
  return value
      .whereType<Map>()
      .map((row) => Map<String, dynamic>.from(row))
      .toList(growable: false);
}

double _number(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? 0;
}

double? _positiveNumber(dynamic value) {
  final parsed = _number(value);
  return parsed > 0 && parsed.isFinite ? parsed : null;
}

double _roundVnd(double value) {
  if (!value.isFinite || value <= 0) return 0;
  return (value / 1000).round() * 1000.0;
}

double _roundTwoDecimals(double value) => (value * 100).round() / 100;

int _nonNegativeInt(dynamic value) => math.max(0, _number(value).round());
