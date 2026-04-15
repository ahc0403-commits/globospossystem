import '../../main.dart';

class TablesService {
  Future<List<Map<String, dynamic>>> fetchTables(String storeId) async {
    final response = await supabase
        .from('tables')
        .select()
        .eq('restaurant_id', storeId)
        .order('table_number');
    return response
        .map<Map<String, dynamic>>((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  Future<void> addTable(
    String storeId,
    String tableNumber,
    int seatCount,
  ) async {
    await supabase.rpc(
      'admin_create_table',
      params: {
        'p_store_id': storeId,
        'p_table_number': tableNumber,
        'p_seat_count': seatCount,
      },
    );
  }

  Future<void> deleteTable(String tableId, String storeId) async {
    await supabase.rpc('admin_delete_table', params: {'p_table_id': tableId});
  }

  Future<void> updateTableStatus(
    String tableId,
    String status,
    String storeId,
  ) async {
    await supabase.rpc(
      'admin_update_table',
      params: {'p_table_id': tableId, 'p_status': status},
    );
  }
}

final tablesService = TablesService();
