import 'pos_backend.dart';
import '../../features/restaurant_sales_export/daily_sales_report_service.dart';

class DailyClosingService {
  Future<Map<String, dynamic>> fetchCashPreview({
    required String storeId,
    required String closingDate,
  }) async {
    final result = await supabase.rpc(
      'get_daily_closing_cash_preview',
      params: {'p_store_id': storeId, 'p_closing_date': closingDate},
    );
    return Map<String, dynamic>.from(result as Map);
  }

  Future<void> createDailyClosing({
    required String storeId,
    required String closingDate,
    required Map<String, int> cashDenominations,
    double openingCashAmount = 5000000,
    String? notes,
  }) async {
    await supabase.rpc(
      'create_daily_closing',
      params: {
        'p_store_id': storeId,
        'p_closing_date': closingDate,
        'p_cash_denominations': cashDenominations,
        'p_opening_cash_amount': openingCashAmount,
        if (notes != null && notes.isNotEmpty) 'p_notes': notes,
      },
    );
    dailySalesReportService.invalidateSummary(closingDate);
  }

  Future<List<Map<String, dynamic>>> fetchDailyClosings({
    required String storeId,
    int limit = 30,
    String? closingDate,
  }) async {
    final result = await supabase.rpc(
      'get_daily_closing_deposit_days',
      params: {
        'p_store_id': storeId,
        'p_limit': limit,
        if (closingDate != null) 'p_closing_date': closingDate,
      },
    );

    return List<Map<String, dynamic>>.from(
      (result as List).map((row) => Map<String, dynamic>.from(row)),
    );
  }
}

final dailyClosingService = DailyClosingService();
