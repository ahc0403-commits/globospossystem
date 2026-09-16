import 'dart:math' as math;

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/utils/floor_label.dart';
import 'revenue_forecast_engine.dart';

class RevenueForecastOperationalDefaults {
  const RevenueForecastOperationalDefaults({
    required this.profile,
    required this.usesMeasuredOperations,
    required this.usesFallbackAssumptions,
  });

  final RestaurantForecastProfile profile;
  final bool usesMeasuredOperations;
  final bool usesFallbackAssumptions;
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
    try {
      final range = _reportUtcRange(trainingStart, trainingEnd);
      final response = await _client.rpc(
        'get_paperless_operations_insights_report',
        params: {
          'p_store_id': storeId,
          'p_from': range.startUtc.toIso8601String(),
          'p_to': range.endExclusiveUtc.toIso8601String(),
        },
      );
      if (response is Map) {
        operations = Map<String, dynamic>.from(response);
      }
    } catch (_) {
      // Table configuration is still authoritative and useful when a store
      // has no paperless timing samples or the optional analytics RPC fails.
    }

    return deriveRestaurantForecastDefaults(
      tables: tables,
      operations: operations,
      observations: observations,
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
    operations['average_operation_seconds'] ??
        operations['average_total_seconds'],
  );
  final measuredDiningSeconds = _positiveNumber(
    operations['average_dining_seconds'],
  );
  final firstServeMinutes = measuredFirstServeSeconds == null
      ? 15.0
      : (measuredFirstServeSeconds / 60).clamp(1, 180).toDouble();
  final diningMinutes = measuredDiningSeconds == null
      ? 60.0
      : (measuredDiningSeconds / 60).clamp(10, 240).toDouble();
  const paymentWaitMinutes = 5.0;
  const cleanupMinutes = 10.0;
  final tableCycleMinutes =
      firstServeMinutes + diningMinutes + paymentWaitMinutes + cleanupMinutes;

  final hourlyRows = _maps(operations['hourly_orders']);
  final peakOrders = hourlyRows.fold<double>(
    0,
    (peak, row) => math.max(peak, _number(row['order_count'])),
  );
  final peakCompleted = hourlyRows.fold<double>(
    0,
    (peak, row) => math.max(peak, _number(row['completed_count'])),
  );
  final operatingMinutes = _operatingMinutes(hourlyRows) ?? 720;
  final neutralHourlyCapacity = totalTables * 60 / tableCycleMinutes;
  final kitchenRate = peakOrders > 0
      ? math.max(1.0, peakOrders * 1.15)
      : math.max(1.0, neutralHourlyCapacity);
  final checkerRate = peakCompleted > 0
      ? math.max(1.0, peakCompleted * 1.15)
      : math.max(1.0, neutralHourlyCapacity);
  final floorTotalRate = peakCompleted > 0
      ? math.max(1.0, peakCompleted * 1.15)
      : math.max(1.0, neutralHourlyCapacity);

  final floors = <RestaurantFloorCapacity>[
    for (final label in floorLabels)
      RestaurantFloorCapacity(
        label: displayFloorLabel(label),
        tableCount: tableCounts[label]!,
        serviceUnitsPerHour: math.max(
          0.1,
          floorTotalRate * tableCounts[label]! / totalTables,
        ),
      ),
  ];

  final operatingWeekdays = <int>{
    for (final row in observations)
      if (row.revenueVnd > 0 || row.dineInRevenueVnd > 0) row.date.weekday,
  };
  if (operatingWeekdays.isEmpty) {
    operatingWeekdays.addAll(const {1, 2, 3, 4, 5, 6, 7});
  }

  final observedUnits = observations.fold<double>(
    0,
    (sum, row) => sum + ((row.units ?? 0) > 0 ? row.units! : 0),
  );
  final dineInRevenue = observations.fold<double>(
    0,
    (sum, row) => sum + math.max(0, row.dineInRevenueVnd),
  );
  final totalRevenue = observations.fold<double>(
    0,
    (sum, row) => sum + math.max(0, row.revenueVnd),
  );
  final operationOrderCount = _positiveNumber(operations['order_count']);
  final averageTicket = observedUnits > 0 && dineInRevenue > 0
      ? dineInRevenue / observedUnits
      : operationOrderCount != null && totalRevenue > 0
      ? totalRevenue / operationOrderCount
      : 250000.0;

  final usesMeasuredOperations =
      measuredFirstServeSeconds != null ||
      measuredDiningSeconds != null ||
      hourlyRows.isNotEmpty;
  // Payment wait and cleanup do not yet have dedicated event timestamps, so
  // every generated profile includes at least those conservative assumptions.
  const usesFallbackAssumptions = true;

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
    usesFallbackAssumptions: usesFallbackAssumptions,
  );
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

int? _operatingMinutes(List<Map<String, dynamic>> hourlyRows) {
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
  var longest = 0;
  for (final hours in hoursByDay.values) {
    final first = hours.reduce(math.min);
    final last = hours.reduce(math.max);
    longest = math.max(longest, (last - first + 1) * 60);
  }
  return longest.clamp(360, 960);
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
  if (!value.isFinite || value <= 0) return 250000;
  return (value / 1000).round() * 1000.0;
}
