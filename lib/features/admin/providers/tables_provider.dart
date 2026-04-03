import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../main.dart';

class TableOrderSummary {
  const TableOrderSummary({
    required this.orderId,
    required this.itemCount,
    required this.createdAt,
  });

  final String orderId;
  final int itemCount;
  final DateTime createdAt;

  int get elapsedMinutes => DateTime.now().difference(createdAt).inMinutes;
}

class TablesState {
  const TablesState({
    this.tables = const <Map<String, dynamic>>[],
    this.activeOrderSummaryByTableId = const <String, TableOrderSummary>{},
    this.isLoading = false,
    this.error,
  });

  final List<Map<String, dynamic>> tables;
  final Map<String, TableOrderSummary> activeOrderSummaryByTableId;
  final bool isLoading;
  final String? error;

  TablesState copyWith({
    List<Map<String, dynamic>>? tables,
    Map<String, TableOrderSummary>? activeOrderSummaryByTableId,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return TablesState(
      tables: tables ?? this.tables,
      activeOrderSummaryByTableId:
          activeOrderSummaryByTableId ?? this.activeOrderSummaryByTableId,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class TablesNotifier extends StateNotifier<TablesState> {
  TablesNotifier(this.restaurantId) : super(const TablesState()) {
    fetchTables();
  }

  final String restaurantId;

  Future<void> fetchTables() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final response = await supabase
          .from('tables')
          .select()
          .eq('restaurant_id', restaurantId)
          .order('table_number');

      final tables = response
          .map<Map<String, dynamic>>(
            (table) => Map<String, dynamic>.from(table),
          )
          .toList();

      final occupiedTableIds = tables
          .where((table) {
            final occupied = table['is_occupied'];
            if (occupied is bool) {
              return occupied;
            }
            return table['status']?.toString().toLowerCase() == 'occupied';
          })
          .map((table) => table['id']?.toString() ?? '')
          .where((id) => id.isNotEmpty)
          .toList();

      final summaryByTableId = <String, TableOrderSummary>{};
      if (occupiedTableIds.isNotEmpty) {
        final orders = await supabase
            .from('orders')
            .select('id, table_id, created_at, status, order_items(id)')
            .eq('restaurant_id', restaurantId)
            .inFilter('status', ['pending', 'confirmed', 'serving'])
            .inFilter('table_id', occupiedTableIds)
            .order('created_at', ascending: false);

        for (final rawOrder in orders) {
          final order = Map<String, dynamic>.from(rawOrder);
          final tableId = order['table_id']?.toString() ?? '';
          if (tableId.isEmpty || summaryByTableId.containsKey(tableId)) {
            continue;
          }
          final itemsRaw = order['order_items'];
          final itemCount = itemsRaw is List ? itemsRaw.length : 0;
          final createdAtRaw = order['created_at']?.toString();
          final createdAt = createdAtRaw == null
              ? DateTime.now()
              : DateTime.tryParse(createdAtRaw) ?? DateTime.now();

          summaryByTableId[tableId] = TableOrderSummary(
            orderId: order['id']?.toString() ?? '',
            itemCount: itemCount,
            createdAt: createdAt,
          );
        }
      }

      state = state.copyWith(
        tables: tables,
        activeOrderSummaryByTableId: summaryByTableId,
        isLoading: false,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load tables: $error',
      );
    }
  }

  Future<void> addTable(String tableNumber, int seatCount) async {
    try {
      await supabase.from('tables').insert({
        'restaurant_id': restaurantId,
        'table_number': tableNumber,
        'seat_count': seatCount,
      });
      await fetchTables();
    } catch (error) {
      state = state.copyWith(error: 'Failed to add table: $error');
    }
  }

  Future<void> deleteTable(String id) async {
    try {
      await supabase.from('tables').delete().eq('id', id);
      await fetchTables();
    } catch (error) {
      state = state.copyWith(error: 'Failed to delete table: $error');
    }
  }
}

final tablesProvider = StateNotifierProvider.autoDispose
    .family<TablesNotifier, TablesState, String>(
      (ref, restaurantId) => TablesNotifier(restaurantId),
    );
