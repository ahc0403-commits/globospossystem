import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../main.dart';

class TablesNotifier extends StateNotifier<AsyncValue<List<Map<String, dynamic>>>> {
  TablesNotifier(this.restaurantId) : super(const AsyncValue.loading()) {
    fetchTables();
  }

  final String restaurantId;

  Future<void> fetchTables() async {
    state = const AsyncValue.loading();
    try {
      final response = await supabase
          .from('tables')
          .select()
          .eq('restaurant_id', restaurantId)
          .order('table_number');

      final tables = response
          .map<Map<String, dynamic>>((table) => Map<String, dynamic>.from(table))
          .toList();

      state = AsyncValue.data(tables);
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
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
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }

  Future<void> deleteTable(String id) async {
    try {
      await supabase.from('tables').delete().eq('id', id);
      await fetchTables();
    } catch (error, stackTrace) {
      state = AsyncValue.error(error, stackTrace);
    }
  }
}

final tablesProvider = StateNotifierProvider.autoDispose
    .family<TablesNotifier, AsyncValue<List<Map<String, dynamic>>>, String>(
      (ref, restaurantId) => TablesNotifier(restaurantId),
    );
