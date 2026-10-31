import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/pos_backend.dart';

enum ServiceStationKind { kitchen, tray, floor }

class StoreServiceStation {
  const StoreServiceStation({
    required this.id,
    required this.kind,
    required this.userIds,
    this.areaId,
    this.storedFloor,
  });

  final String id;
  final ServiceStationKind kind;
  final String? areaId;
  final String? storedFloor;
  final List<String> userIds;

  factory StoreServiceStation.fromJson(Map<String, dynamic> json) {
    final kind = ServiceStationKind.values.byName(json['kind'] as String);
    if (kind == ServiceStationKind.floor &&
        (json['area_id'] == null || json['stored_floor'] == null)) {
      throw const FormatException('OPERATING_PROFILE_STATION_INVALID');
    }
    return StoreServiceStation(
      id: json['id'] as String,
      kind: kind,
      areaId: json['area_id'] as String?,
      storedFloor: json['stored_floor'] as String?,
      userIds: List<String>.unmodifiable(json['user_ids'] as List),
    );
  }
}

class StoreOperatingProfile {
  const StoreOperatingProfile({
    required this.restaurantId,
    required this.revision,
    required this.sourceMatches,
    required this.workflow,
    required this.stations,
    this.baselineVersionId,
  });

  final String restaurantId;
  final int revision;
  final bool sourceMatches;
  final String workflow;
  final String? baselineVersionId;
  final List<StoreServiceStation> stations;

  factory StoreOperatingProfile.fromJson(Map<String, dynamic> json) {
    // Configuration versions must never be confused with the KDS 1/2 protocol.
    if (json['runtime_authority'] != 'legacy' ||
        json['definition_schema_version'] != 1 ||
        !{'kitchen_tray_floor', 'kitchen_floor'}.contains(json['workflow'])) {
      throw const FormatException('OPERATING_PROFILE_VERSION_UNSUPPORTED');
    }
    final revision = (json['revision'] as num).toInt();
    if (revision < 0 || (revision > 0 && json['baseline_version_id'] == null)) {
      throw const FormatException('OPERATING_PROFILE_REVISION_INVALID');
    }
    return StoreOperatingProfile(
      restaurantId: json['restaurant_id'] as String,
      revision: revision,
      sourceMatches: json['source_matches'] == true,
      workflow: json['workflow'] as String,
      baselineVersionId: json['baseline_version_id'] as String?,
      stations: List.unmodifiable(
        (json['stations'] as List).map(
          (row) => StoreServiceStation.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
        ),
      ),
    );
  }
}

abstract interface class StoreOperatingProfileBackend {
  Future<StoreOperatingProfile?> load(String restaurantId);
  Future<StoreOperatingProfile> capture(String restaurantId, int revision);
}

class SupabaseStoreOperatingProfileBackend
    implements StoreOperatingProfileBackend {
  SupabaseStoreOperatingProfileBackend([SupabaseClient? client])
    : _client = client ?? supabase;

  final SupabaseClient _client;

  StoreOperatingProfile _parse(Object? raw, String restaurantId) {
    final result = StoreOperatingProfile.fromJson(
      Map<String, dynamic>.from(raw as Map),
    );
    if (result.restaurantId != restaurantId) {
      throw const FormatException('OPERATING_PROFILE_STORE_MISMATCH');
    }
    return result;
  }

  @override
  Future<StoreOperatingProfile?> load(String restaurantId) async {
    const rpc = 'admin_get_store_operating_profile_v1';
    try {
      final raw = await _client.rpc(rpc, params: {'p_store_id': restaurantId});
      return _parse(raw, restaurantId);
    } on PostgrestException catch (error) {
      // A frontend may precede this additive migration. Do not turn permission,
      // malformed-data, transport, or missing dependency errors into success.
      if (error.code == 'PGRST202' && error.message.contains(rpc)) return null;
      rethrow;
    }
  }

  @override
  Future<StoreOperatingProfile> capture(
    String restaurantId,
    int revision,
  ) async {
    final raw = await _client.rpc(
      'admin_capture_store_operating_baseline_v1',
      params: {'p_store_id': restaurantId, 'p_expected_revision': revision},
    );
    return _parse(raw, restaurantId);
  }
}
