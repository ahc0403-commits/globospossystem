import '../../main.dart';

class DailyClosingService {
  Future<void> createDailyClosing({
    required String storeId,
    String? notes,
  }) async {
    await supabase.rpc(
      'create_daily_closing',
      params: {
        'p_restaurant_id': storeId,
        if (notes != null && notes.isNotEmpty) 'p_notes': notes,
      },
    );
  }

  Future<List<Map<String, dynamic>>> fetchDailyClosings({
    required String storeId,
    int limit = 30,
  }) async {
    final result = await supabase.rpc(
      'get_daily_closings',
      params: {'p_restaurant_id': storeId, 'p_limit': limit},
    );

    return List<Map<String, dynamic>>.from(
      (result as List).map((row) => Map<String, dynamic>.from(row)),
    );
  }
}

final dailyClosingService = DailyClosingService();
