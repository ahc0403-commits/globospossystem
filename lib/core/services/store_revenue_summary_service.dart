import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef StoreRevenueTotals = ({double dineIn, double delivery});

/// A complete aggregate for the requested stores. Never accepts a partial row
/// set or falls back to downloading transaction history on RPC failure.
class StoreRevenueSummaryService {
  const StoreRevenueSummaryService(this.client);

  final SupabaseClient client;

  Future<Map<String, StoreRevenueTotals>> fetch({
    required List<String> storeIds,
    required DateTime fromDate,
    required DateTime toDate,
  }) async {
    final scope = Set<String>.of(storeIds);
    final from = DateFormat('yyyy-MM-dd').format(fromDate);
    final to = DateFormat('yyyy-MM-dd').format(toDate);
    if (scope.isEmpty ||
        scope.length > 500 ||
        scope.length != storeIds.length ||
        scope.contains('') ||
        to.compareTo(from) < 0) {
      throw ArgumentError('STORE_REVENUE_QUERY_INVALID');
    }
    final response = await client.rpc(
      'get_store_revenue_summary',
      params: {
        'p_store_ids': scope.toList(growable: false),
        'p_from_date': from,
        'p_to_date': to,
      },
    );
    if (response is! Map ||
        response['version'] != 1 ||
        response['from_date'] != from ||
        response['to_date'] != to ||
        response['store_count'] != scope.length ||
        response['rows'] is! List ||
        (response['rows'] as List).length != scope.length) {
      throw const FormatException('STORE_REVENUE_RESPONSE_INVALID');
    }
    final result = <String, StoreRevenueTotals>{};
    for (final row in response['rows'] as List) {
      if (row is! Map ||
          !scope.contains(row['store_id']) ||
          result.containsKey(row['store_id'])) {
        throw const FormatException('STORE_REVENUE_SCOPE_INVALID');
      }
      result[row['store_id'] as String] = (
        dineIn: _amount(row['dine_in']),
        delivery: _amount(row['delivery']),
      );
    }
    return Map.unmodifiable(result);
  }

  static double _amount(dynamic value) {
    final amount = value is num
        ? value.toDouble()
        : value is String
        ? double.tryParse(value)
        : null;
    if (amount == null || !amount.isFinite) {
      throw const FormatException('STORE_REVENUE_AMOUNT_INVALID');
    }
    return amount;
  }
}
