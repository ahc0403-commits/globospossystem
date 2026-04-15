import '../../main.dart';

class AdminAuditService {
  Future<List<Map<String, dynamic>>> fetchRecentMutationTrace({
    required String storeId,
    int limit = 10,
  }) async {
    final result = await supabase.rpc(
      'get_admin_mutation_audit_trace',
      params: {'p_store_id': storeId, 'p_limit': limit},
    );

    return List<Map<String, dynamic>>.from(
      (result as List).map((row) => Map<String, dynamic>.from(row)),
    );
  }

  Future<Map<String, dynamic>> fetchTodaySummary({
    required String storeId,
  }) async {
    final result = await supabase.rpc(
      'get_admin_today_summary',
      params: {'p_store_id': storeId},
    );

    return Map<String, dynamic>.from(result as Map);
  }
}

final adminAuditService = AdminAuditService();
