import '../../main.dart';

class TablesService {
  Future<List<Map<String, dynamic>>> fetchTables(String restaurantId) async {
    final response = await supabase
        .from('tables')
        .select()
        .eq('restaurant_id', restaurantId)
        .order('table_number');
    return response
        .map<Map<String, dynamic>>((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  Future<void> addTable(
    String restaurantId,
    String tableNumber,
    int seatCount,
  ) async {
    await supabase.from('tables').insert({
      'restaurant_id': restaurantId,
      'table_number': tableNumber,
      'seat_count': seatCount,
      'status': 'available',
    });
  }

  Future<void> deleteTable(String tableId) async {
    await supabase.from('tables').delete().eq('id', tableId);
  }

  Future<void> updateTableStatus(String tableId, String status) async {
    await supabase
        .from('tables')
        .update({
          'status': status,
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', tableId);
  }
}

final tablesService = TablesService();
