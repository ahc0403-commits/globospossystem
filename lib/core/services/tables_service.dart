import '../../main.dart';

class TablesService {
  Future<List<Map<String, dynamic>>> fetchTables(String storeId) async {
    final response = await _fetchTablesWithLayout(storeId);
    return response
        .map<Map<String, dynamic>>((row) => Map<String, dynamic>.from(row))
        .toList();
  }

  Future<List<dynamic>> _fetchTablesWithLayout(String storeId) async {
    try {
      return await supabase
          .from('tables')
          .select()
          .eq('restaurant_id', storeId)
          .order('layout_sort_order')
          .order('table_number');
    } catch (error) {
      final message = error.toString();
      if (!message.contains('layout_sort_order') &&
          !message.contains('is_occupied')) {
        rethrow;
      }
      final legacyRows = await supabase
          .from('tables')
          .select(
            'id,restaurant_id,table_number,status,seat_count,created_at,updated_at',
          )
          .eq('restaurant_id', storeId)
          .order('table_number');
      return legacyRows.map((raw) {
        final row = Map<String, dynamic>.from(raw as Map);
        row['is_occupied'] =
            row['status']?.toString().toLowerCase() == 'occupied';
        row['layout_x'] ??= 0.0;
        row['layout_y'] ??= 0.0;
        row['layout_w'] ??= 0.22;
        row['layout_h'] ??= 0.16;
        row['layout_rotation'] ??= 0;
        row['layout_shape'] ??= 'rectangle';
        row['layout_sort_order'] ??= 0;
        return row;
      }).toList();
    }
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
    await supabase.rpc(
      'admin_delete_table',
      params: {'p_table_id': tableId, 'p_store_id': storeId},
    );
  }

  Future<void> updateTableStatus(
    String tableId,
    String status,
    String storeId,
  ) async {
    await supabase.rpc(
      'admin_update_table',
      params: {
        'p_table_id': tableId,
        'p_store_id': storeId,
        'p_status': status,
      },
    );
  }

  Future<void> updateTableLayout({
    required String tableId,
    required String storeId,
    required double layoutX,
    required double layoutY,
    required double layoutW,
    required double layoutH,
    required int layoutRotation,
    required String layoutShape,
    required int layoutSortOrder,
  }) async {
    await supabase.rpc(
      'admin_update_table',
      params: {
        'p_table_id': tableId,
        'p_store_id': storeId,
        'p_layout_x': layoutX,
        'p_layout_y': layoutY,
        'p_layout_w': layoutW,
        'p_layout_h': layoutH,
        'p_layout_rotation': layoutRotation,
        'p_layout_shape': layoutShape,
        'p_layout_sort_order': layoutSortOrder,
      },
    );
  }
}

final tablesService = TablesService();
