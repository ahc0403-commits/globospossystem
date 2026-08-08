import '../../main.dart';

class DailyClosingService {
  Future<Map<String, dynamic>> fetchCashPreview({
    required String storeId,
  }) async {
    final result = await supabase.rpc(
      'get_daily_closing_cash_preview',
      params: {'p_store_id': storeId},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<void> createDailyClosing({
    required String storeId,
    required Map<String, int> cashDenominations,
    double openingCashAmount = 5000000,
    String? notes,
  }) async {
    await supabase.rpc(
      'create_daily_closing',
      params: {
        'p_store_id': storeId,
        'p_cash_denominations': cashDenominations,
        'p_opening_cash_amount': openingCashAmount,
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
      params: {'p_store_id': storeId, 'p_limit': limit},
    );

    return List<Map<String, dynamic>>.from(
      (result as List).map((row) => Map<String, dynamic>.from(row)),
    );
  }
}

final dailyClosingService = DailyClosingService();
