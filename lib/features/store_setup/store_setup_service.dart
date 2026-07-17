import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';
import 'store_setup_models.dart';

class StoreSetupExistingConfig {
  const StoreSetupExistingConfig({
    required this.store,
    required this.tables,
    required this.destinations,
  });

  final Map<String, dynamic> store;
  final List<StoreSetupTableDraft> tables;
  final List<Map<String, dynamic>> destinations;
}

abstract class StoreSetupBackend {
  Future<StoreSetupExistingConfig> loadExisting(String storeId);

  Future<StoreSetupValidationResult> validate(StoreOpeningDraft draft);

  Future<Map<String, dynamic>> apply(StoreOpeningDraft draft);

  Future<Map<String, dynamic>> readiness(String storeId);

  Future<StoreSetupTestJob> enqueueTest({
    required String storeId,
    required LogicalDestinationDraft destination,
    required String destinationId,
  });

  Future<Map<String, Map<String, dynamic>>> fetchTestJobs(
    String storeId,
    Iterable<String> jobIds,
  );
}

class SupabaseStoreSetupBackend implements StoreSetupBackend {
  SupabaseStoreSetupBackend([SupabaseClient? client])
    : _client = client ?? supabase;

  final SupabaseClient _client;

  @override
  Future<StoreSetupExistingConfig> loadExisting(String storeId) async {
    final responses = await Future.wait<dynamic>([
      _client
          .from('restaurants')
          .select(
            'id, name, address, is_active, brand_id, tax_entity_id, '
            'brands(name), tax_entity(name, tax_code)',
          )
          .eq('id', storeId)
          .single(),
      _client
          .from('tables')
          .select('id, table_number, seat_count, floor_label, status')
          .eq('restaurant_id', storeId)
          .order('table_number'),
      _client
          .from('printer_destinations')
          .select('id, name, ip, port, purpose, floor_label, is_active')
          .eq('restaurant_id', storeId)
          .order('purpose'),
    ]);

    return StoreSetupExistingConfig(
      store: Map<String, dynamic>.from(responses[0] as Map),
      tables: (responses[1] as List)
          .whereType<Map>()
          .map(
            (row) =>
                StoreSetupTableDraft.fromJson(Map<String, dynamic>.from(row)),
          )
          .toList(growable: false),
      destinations: (responses[2] as List)
          .whereType<Map>()
          .map((row) => Map<String, dynamic>.from(row))
          .toList(growable: false),
    );
  }

  Map<String, dynamic> _payload(StoreOpeningDraft draft) => {
    'p_store_id': draft.storeId,
    'p_tables': draft.tables.map((table) => table.toJson()).toList(),
    'p_destinations': draft.destinations
        .map((destination) => destination.toJson())
        .toList(),
  };

  @override
  Future<StoreSetupValidationResult> validate(StoreOpeningDraft draft) async {
    final response = await _client.rpc(
      'admin_validate_store_opening_config',
      params: _payload(draft),
    );
    return StoreSetupValidationResult.fromJson(
      Map<String, dynamic>.from(response as Map),
    );
  }

  @override
  Future<Map<String, dynamic>> apply(StoreOpeningDraft draft) async {
    final response = await _client.rpc(
      'admin_apply_store_opening_config',
      params: _payload(draft),
    );
    return Map<String, dynamic>.from(response as Map);
  }

  @override
  Future<Map<String, dynamic>> readiness(String storeId) async {
    final response = await _client.rpc(
      'admin_get_store_opening_readiness',
      params: {'p_store_id': storeId},
    );
    return Map<String, dynamic>.from(response as Map);
  }

  @override
  Future<StoreSetupTestJob> enqueueTest({
    required String storeId,
    required LogicalDestinationDraft destination,
    required String destinationId,
  }) async {
    final response = await _client.rpc(
      'admin_enqueue_printer_test_job',
      params: {'p_store_id': storeId, 'p_destination_id': destinationId},
    );
    final row = Map<String, dynamic>.from(response as Map);
    return StoreSetupTestJob(
      label: destination.label,
      destinationId: destinationId,
      jobId: row['id']?.toString() ?? '',
      status: row['status']?.toString() ?? 'pending',
      error: row['last_error']?.toString(),
    );
  }

  @override
  Future<Map<String, Map<String, dynamic>>> fetchTestJobs(
    String storeId,
    Iterable<String> jobIds,
  ) async {
    final ids = jobIds.where((id) => id.isNotEmpty).toList(growable: false);
    if (ids.isEmpty) return const {};
    final rows = await _client
        .from('print_jobs')
        .select('id, status, last_error, updated_at')
        .eq('restaurant_id', storeId)
        .inFilter('id', ids);
    return {
      for (final row in rows)
        row['id'].toString(): Map<String, dynamic>.from(row),
    };
  }
}
