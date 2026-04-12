import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';
import 'table_model.dart';

class WaiterTableState {
  const WaiterTableState({
    this.tables = const [],
    this.isLoading = false,
    this.error,
  });

  final List<PosTable> tables;
  final bool isLoading;
  final String? error;

  WaiterTableState copyWith({
    List<PosTable>? tables,
    bool? isLoading,
    String? error,
    bool clearError = false,
  }) {
    return WaiterTableState(
      tables: tables ?? this.tables,
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class WaiterTableNotifier extends StateNotifier<WaiterTableState> {
  WaiterTableNotifier() : super(const WaiterTableState());

  RealtimeChannel? _channel;
  String? _subscribedRestaurantId;

  Future<void> loadTables(String storeId) async {
    state = state.copyWith(isLoading: true, clearError: true);
    try {
      final response = await supabase
          .from('tables')
          .select()
          .eq('restaurant_id', storeId)
          .order('table_number', ascending: true);

      final tables = response
          .map<PosTable>((row) => PosTable.fromJson(Map<String, dynamic>.from(row)))
          .toList();

      state = state.copyWith(
        tables: _sortTables(tables),
        isLoading: false,
        clearError: true,
      );

      await subscribe(storeId);
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load tables: $error',
      );
    }
  }

  Future<void> subscribe(String storeId) async {
    if (_subscribedRestaurantId == storeId && _channel != null) {
      return;
    }

    if (_channel != null) {
      await _channel!.unsubscribe();
      _channel = null;
    }

    _subscribedRestaurantId = storeId;

    _channel = supabase
        .channel('public:tables:$storeId')
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'tables',
          callback: (payload) {
            final raw = payload.newRecord;
            if (raw.isEmpty) {
              return;
            }

            final updated = PosTable.fromJson(Map<String, dynamic>.from(raw));
            if (updated.storeId != storeId) {
              return;
            }

            final current = [...state.tables];
            final index = current.indexWhere((table) => table.id == updated.id);
            if (index >= 0) {
              current[index] = updated;
            } else {
              current.add(updated);
            }

            state = state.copyWith(tables: _sortTables(current), clearError: true);
          },
        )
        .subscribe();
  }

  List<PosTable> _sortTables(List<PosTable> tables) {
    final sorted = [...tables];
    sorted.sort((a, b) {
      final aNum = int.tryParse(a.tableNumber);
      final bNum = int.tryParse(b.tableNumber);
      if (aNum != null && bNum != null) {
        return aNum.compareTo(bNum);
      }
      return a.tableNumber.compareTo(b.tableNumber);
    });
    return sorted;
  }

  @override
  void dispose() {
    _channel?.unsubscribe();
    _channel = null;
    super.dispose();
  }
}

final waiterTableProvider =
    StateNotifierProvider<WaiterTableNotifier, WaiterTableState>(
      (ref) => WaiterTableNotifier(),
    );
