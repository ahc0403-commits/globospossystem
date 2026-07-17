import '../../main.dart';

class TablesService {
  bool _isRpcSignatureMismatch(Object error, String functionName) {
    final message = error.toString().toLowerCase();
    if (!message.contains(functionName.toLowerCase())) {
      return false;
    }

    return message.contains('could not find the function') ||
        message.contains('function public.') ||
        message.contains('does not exist') ||
        message.contains('no function matches');
  }

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
      return legacyRows.asMap().entries.map((entry) {
        final index = entry.key;
        final raw = entry.value;
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
        row['floor_label'] ??= '1F';
        final col = index % 4;
        final rowIndex = index ~/ 4;
        if ((row['layout_x'] as num?)?.toDouble() == 0.0 &&
            (row['layout_y'] as num?)?.toDouble() == 0.0) {
          row['layout_x'] = 0.04 + (col * 0.235);
          row['layout_y'] = 0.06 + (rowIndex * 0.22);
          row['layout_w'] = 0.2;
          row['layout_h'] = 0.16;
          row['layout_sort_order'] = index;
        }
        return row;
      }).toList();
    }
  }

  Future<void> addTable(
    String storeId,
    String tableNumber,
    int seatCount,
    String floorLabel,
  ) async {
    try {
      await supabase.rpc(
        'admin_create_table',
        params: {
          'p_store_id': storeId,
          'p_table_number': tableNumber,
          'p_seat_count': seatCount,
          'p_floor_label': floorLabel,
        },
      );
    } catch (error) {
      if (!_isRpcSignatureMismatch(error, 'admin_create_table')) {
        rethrow;
      }

      try {
        await supabase.rpc(
          'admin_create_table',
          params: {
            'p_store_id': storeId,
            'p_table_number': tableNumber,
            'p_seat_count': seatCount,
          },
        );
        return;
      } catch (legacyStoreError) {
        if (!_isRpcSignatureMismatch(legacyStoreError, 'admin_create_table')) {
          rethrow;
        }
      }

      await supabase.rpc(
        'admin_create_table',
        params: {
          'p_restaurant_id': storeId,
          'p_table_number': tableNumber,
          'p_seat_count': seatCount,
        },
      );
    }
  }

  Future<void> updateTableDetails({
    required String tableId,
    required String storeId,
    required String tableNumber,
    required int seatCount,
    required String floorLabel,
  }) async {
    try {
      await supabase.rpc(
        'admin_update_table',
        params: {
          'p_table_id': tableId,
          'p_store_id': storeId,
          'p_table_number': tableNumber,
          'p_seat_count': seatCount,
          'p_floor_label': floorLabel,
        },
      );
    } catch (error) {
      if (!_isRpcSignatureMismatch(error, 'admin_update_table')) {
        rethrow;
      }

      await supabase.rpc(
        'admin_update_table',
        params: {
          'p_table_id': tableId,
          'p_table_number': tableNumber,
          'p_seat_count': seatCount,
        },
      );
    }
  }

  Future<void> deleteTable(String tableId, String storeId) async {
    try {
      await supabase.rpc(
        'admin_delete_table',
        params: {'p_table_id': tableId, 'p_store_id': storeId},
      );
    } catch (error) {
      if (!_isRpcSignatureMismatch(error, 'admin_delete_table')) {
        rethrow;
      }

      await supabase.rpc('admin_delete_table', params: {'p_table_id': tableId});
    }
  }

  Future<void> updateTableStatus(
    String tableId,
    String status,
    String storeId,
  ) async {
    try {
      await supabase.rpc(
        'admin_update_table',
        params: {
          'p_table_id': tableId,
          'p_store_id': storeId,
          'p_status': status,
        },
      );
    } catch (error) {
      if (!_isRpcSignatureMismatch(error, 'admin_update_table')) {
        rethrow;
      }

      await supabase.rpc(
        'admin_update_table',
        params: {'p_table_id': tableId, 'p_status': status},
      );
    }
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
    final legacyLayoutParams = {
      'p_table_id': tableId,
      'p_layout_x': layoutX,
      'p_layout_y': layoutY,
      'p_layout_w': layoutW,
      'p_layout_h': layoutH,
      'p_layout_rotation': layoutRotation,
      'p_layout_shape': layoutShape,
      'p_layout_sort_order': layoutSortOrder,
    };

    try {
      await supabase.rpc(
        'admin_update_table',
        params: {
          'p_table_id': tableId,
          'p_store_id': storeId,
          ...legacyLayoutParams,
        },
      );
    } catch (error) {
      if (!_isRpcSignatureMismatch(error, 'admin_update_table')) {
        rethrow;
      }

      await supabase.rpc('admin_update_table', params: legacyLayoutParams);
    }
  }

  Future<Map<String, dynamic>> generateTableQr(String tableId) async {
    final response = await supabase.rpc(
      'admin_generate_table_qr',
      params: {'p_table_id': tableId},
    );
    return Map<String, dynamic>.from(response as Map);
  }

  Future<List<Map<String, dynamic>>> getOrCreateTableQrs({
    required String storeId,
    List<String>? tableIds,
  }) async {
    final response = await supabase.rpc(
      'admin_get_or_create_table_qrs',
      params: {'p_store_id': storeId, 'p_table_ids': tableIds},
    );
    final rows = (response as List<dynamic>)
        .map((row) => Map<String, dynamic>.from(row as Map))
        .toList();
    rows.sort((left, right) {
      final leftOrder = _intValue(left['layout_sort_order']);
      final rightOrder = _intValue(right['layout_sort_order']);
      final orderCompare = leftOrder.compareTo(rightOrder);
      if (orderCompare != 0) {
        return orderCompare;
      }
      final tableCompare = (left['table_number']?.toString() ?? '').compareTo(
        right['table_number']?.toString() ?? '',
      );
      if (tableCompare != 0) {
        return tableCompare;
      }
      return (left['table_id']?.toString() ?? '').compareTo(
        right['table_id']?.toString() ?? '',
      );
    });
    return rows;
  }

  int _intValue(dynamic value) {
    return switch (value) {
      int raw => raw,
      num raw => raw.toInt(),
      String raw => int.tryParse(raw) ?? 0,
      _ => 0,
    };
  }
}

final tablesService = TablesService();
