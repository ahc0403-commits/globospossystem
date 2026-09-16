import 'package:supabase_flutter/supabase_flutter.dart';

import 'revenue_forecast_engine.dart';

class RevenueForecastProfileSnapshot {
  const RevenueForecastProfileSnapshot({
    required this.storeId,
    required this.revision,
    required this.businessType,
    required this.settings,
    required this.effectiveFrom,
  });

  final String storeId;
  final int revision;
  final ForecastBusinessType businessType;
  final Map<String, dynamic> settings;
  final DateTime effectiveFrom;

  RestaurantForecastProfile? get restaurantProfile =>
      businessType == ForecastBusinessType.restaurant
      ? restaurantProfileFromJson(settings)
      : null;

  PhotoForecastProfile? get photoProfile =>
      businessType == ForecastBusinessType.photo
      ? photoProfileFromJson(settings)
      : null;
}

abstract interface class RevenueForecastProfileRepository {
  Future<RevenueForecastProfileSnapshot?> load(String storeId);

  Future<RevenueForecastProfileSnapshot> saveRestaurant({
    required String storeId,
    required int expectedRevision,
    required RestaurantForecastProfile profile,
  });

  Future<RevenueForecastProfileSnapshot> savePhoto({
    required String storeId,
    required int expectedRevision,
    required PhotoForecastProfile profile,
  });
}

class RevenueForecastProfileService
    implements RevenueForecastProfileRepository {
  RevenueForecastProfileService(this._client);

  final SupabaseClient _client;

  @override
  Future<RevenueForecastProfileSnapshot?> load(String storeId) async {
    final response = await _client.rpc(
      'get_revenue_forecast_profile',
      params: {'p_store_id': storeId},
    );
    if (response == null) return null;
    final row = Map<String, dynamic>.from(response as Map);
    if (row.isEmpty || row['revision'] == null) return null;
    return _snapshot(row);
  }

  @override
  Future<RevenueForecastProfileSnapshot> saveRestaurant({
    required String storeId,
    required int expectedRevision,
    required RestaurantForecastProfile profile,
  }) => _save(
    storeId: storeId,
    expectedRevision: expectedRevision,
    businessType: ForecastBusinessType.restaurant,
    settings: restaurantProfileToJson(profile),
  );

  @override
  Future<RevenueForecastProfileSnapshot> savePhoto({
    required String storeId,
    required int expectedRevision,
    required PhotoForecastProfile profile,
  }) => _save(
    storeId: storeId,
    expectedRevision: expectedRevision,
    businessType: ForecastBusinessType.photo,
    settings: photoProfileToJson(profile),
  );

  Future<RevenueForecastProfileSnapshot> _save({
    required String storeId,
    required int expectedRevision,
    required ForecastBusinessType businessType,
    required Map<String, dynamic> settings,
  }) async {
    final response = await _client.rpc(
      'save_revenue_forecast_profile',
      params: {
        'p_store_id': storeId,
        'p_expected_revision': expectedRevision,
        'p_model_type': businessType.name,
        'p_settings': settings,
      },
    );
    return _snapshot(Map<String, dynamic>.from(response as Map));
  }

  RevenueForecastProfileSnapshot _snapshot(Map<String, dynamic> row) {
    final modelType = row['model_type']?.toString();
    final businessType = ForecastBusinessType.values.where(
      (value) => value.name == modelType,
    );
    if (businessType.isEmpty) {
      throw const FormatException('FORECAST_PROFILE_MODEL_TYPE_INVALID');
    }
    final settingsRaw = row['settings'];
    if (settingsRaw is! Map) {
      throw const FormatException('FORECAST_PROFILE_SETTINGS_INVALID');
    }
    return RevenueForecastProfileSnapshot(
      storeId: row['store_id']?.toString() ?? '',
      revision: _intValue(row['revision']),
      businessType: businessType.first,
      settings: Map<String, dynamic>.from(settingsRaw),
      effectiveFrom:
          DateTime.tryParse(row['effective_from']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

Map<String, dynamic> restaurantProfileToJson(
  RestaurantForecastProfile profile,
) => {
  'floors': [
    for (final floor in profile.floors)
      {
        'label': floor.label,
        'table_count': floor.tableCount,
        'service_units_per_hour': floor.serviceUnitsPerHour,
      },
  ],
  'seated_to_first_serve_minutes': profile.seatedToFirstServeMinutes,
  'dining_minutes': profile.diningMinutes,
  'payment_wait_minutes': profile.paymentWaitMinutes,
  'cleanup_minutes': profile.cleanupMinutes,
  'kitchen_units_per_hour': profile.kitchenUnitsPerHour,
  'checker_units_per_hour': profile.checkerUnitsPerHour,
  'operating_minutes_per_day': profile.operatingMinutesPerDay,
  'operating_weekdays': profile.operatingWeekdays.toList()..sort(),
  'average_ticket_vnd': profile.averageTicketVnd,
};

RestaurantForecastProfile restaurantProfileFromJson(Map<String, dynamic> json) {
  final floorsRaw = json['floors'];
  if (floorsRaw is! List) {
    throw const FormatException('FORECAST_PROFILE_FLOORS_INVALID');
  }
  return RestaurantForecastProfile(
    floors: floorsRaw
        .map((raw) {
          final floor = Map<String, dynamic>.from(raw as Map);
          return RestaurantFloorCapacity(
            label: floor['label']?.toString() ?? '',
            tableCount: _intValue(floor['table_count']),
            serviceUnitsPerHour: _doubleValue(floor['service_units_per_hour']),
          );
        })
        .toList(growable: false),
    seatedToFirstServeMinutes: _doubleValue(
      json['seated_to_first_serve_minutes'],
    ),
    diningMinutes: _doubleValue(json['dining_minutes']),
    paymentWaitMinutes: _doubleValue(json['payment_wait_minutes']),
    cleanupMinutes: _doubleValue(json['cleanup_minutes']),
    kitchenUnitsPerHour: _doubleValue(json['kitchen_units_per_hour']),
    checkerUnitsPerHour: _doubleValue(json['checker_units_per_hour']),
    operatingMinutesPerDay: _intValue(json['operating_minutes_per_day']),
    operatingWeekdays: _weekdaySet(json['operating_weekdays']),
    averageTicketVnd: _doubleValue(json['average_ticket_vnd']),
  );
}

Map<String, dynamic> photoProfileToJson(PhotoForecastProfile profile) => {
  'machine_count': profile.machineCount,
  'operating_minutes_per_day': profile.operatingMinutesPerDay,
  'operating_weekdays': profile.operatingWeekdays.toList()..sort(),
  'free_service_sessions_per_day': profile.freeServiceSessionsPerDay,
};

PhotoForecastProfile photoProfileFromJson(Map<String, dynamic> json) =>
    PhotoForecastProfile(
      machineCount: _intValue(json['machine_count']),
      operatingMinutesPerDay: _intValue(json['operating_minutes_per_day']),
      operatingWeekdays: _weekdaySet(json['operating_weekdays']),
      freeServiceSessionsPerDay: _intValue(
        json['free_service_sessions_per_day'],
      ),
    );

double _doubleValue(dynamic value) {
  if (value is num) return value.toDouble();
  return double.tryParse(value?.toString() ?? '') ?? double.nan;
}

int _intValue(dynamic value) {
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value?.toString() ?? '') ?? -1;
}

Set<int> _weekdaySet(dynamic value) {
  if (value is! List || value.isEmpty) {
    throw const FormatException('FORECAST_PROFILE_OPERATING_WEEKDAYS_INVALID');
  }
  final weekdays = <int>{};
  for (final raw in value) {
    final weekday = raw is int
        ? raw
        : raw is num && raw == raw.toInt()
        ? raw.toInt()
        : int.tryParse(raw?.toString() ?? '');
    if (weekday == null ||
        weekday < DateTime.monday ||
        weekday > DateTime.sunday ||
        !weekdays.add(weekday)) {
      throw const FormatException(
        'FORECAST_PROFILE_OPERATING_WEEKDAYS_INVALID',
      );
    }
  }
  return Set<int>.unmodifiable(weekdays);
}
