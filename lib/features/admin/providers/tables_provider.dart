import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/tables_service.dart';
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
  TablesNotifier(this.storeId) : super(const TablesState()) {
    fetchTables();
  }

  final String storeId;

  String _mapTablesError(Object error, String fallback) {
    if (error is! PostgrestException) {
      return fallback;
    }

    final message = error.message;
    if (message.contains('ADMIN_MUTATION_FORBIDDEN')) {
      return 'No permission to change tables.';
    }
    if (message.contains('TABLE_NUMBER_REQUIRED')) {
      return 'Enter a table number.';
    }
    if (message.contains('TABLE_NOT_FOUND')) {
      return 'Reload tables and try again.';
    }
    if (message.contains('duplicate key value') || message.contains('23505')) {
      return 'A table with the same number already exists.';
    }

    return fallback;
  }

  Future<void> fetchTables() async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final tables = await tablesService.fetchTables(storeId);

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
            .eq('restaurant_id', storeId)
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
      state = state.copyWith(isLoading: false, error: 'Failed to load tables.');
    }
  }

  Future<bool> addTable(String tableNumber, int seatCount) async {
    try {
      await tablesService.addTable(storeId, tableNumber, seatCount);
      await fetchTables();
      return true;
    } catch (error) {
      state = state.copyWith(error: _mapTablesError(error, 'Failed to add table.'));
      return false;
    }
  }

  Future<bool> deleteTable(String id) async {
    try {
      await tablesService.deleteTable(id, storeId);
      await fetchTables();
      return true;
    } catch (error) {
      state = state.copyWith(error: _mapTablesError(error, 'Failed to delete table.'));
      return false;
    }
  }
}

final tablesProvider = StateNotifierProvider.autoDispose
    .family<TablesNotifier, TablesState, String>(
      (ref, storeId) => TablesNotifier(storeId),
    );
