import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

typedef StoreRevenueTotals = ({double dineIn, double delivery});

// The existing non-fiscal test entity used by the invoice/reporting contract.
// Classification follows its stable identity, including after a store rename.
const sampleReportingTaxEntityId = '8f3f3ad8-b47c-5a4a-9b88-2e5e8f38b9c1';

/// A complete aggregate for the requested stores. Never accepts a partial row
/// set or falls back to downloading transaction history on RPC failure.
class StoreRevenueSummaryService {
  const StoreRevenueSummaryService(this.client);

  final SupabaseClient client;

  Future<Map<String, StoreRevenueTotals>> fetch({
    required List<String> storeIds,
    required DateTime fromDate,
    required DateTime toDate,
    bool networkOnly = false,
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
    if (scope.length > 100) {
      final result = <String, StoreRevenueTotals>{};
      for (var offset = 0; offset < storeIds.length; offset += 100) {
        result.addAll(
          await fetch(
            storeIds: storeIds.skip(offset).take(100).toList(),
            fromDate: fromDate,
            toDate: toDate,
            networkOnly: networkOnly,
          ),
        );
      }
      return Map.unmodifiable(result);
    }
    final response = await client.rpc(
      networkOnly
          ? 'get_network_store_revenue_summary'
          : 'get_store_revenue_summary',
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
        response['rows'] is! List) {
      throw const FormatException('STORE_REVENUE_RESPONSE_INVALID');
    }
    final excluded = <String>{};
    if (networkOnly) {
      final rawExcluded = response['excluded_store_ids'];
      if (rawExcluded is! List) {
        throw const FormatException('STORE_REVENUE_EXCLUSIONS_INVALID');
      }
      for (final id in rawExcluded) {
        if (id is! String || !scope.contains(id) || !excluded.add(id)) {
          throw const FormatException('STORE_REVENUE_EXCLUSIONS_INVALID');
        }
      }
    }
    if ((response['rows'] as List).length + excluded.length != scope.length) {
      throw const FormatException('STORE_REVENUE_RESPONSE_INVALID');
    }
    final result = <String, StoreRevenueTotals>{};
    for (final row in response['rows'] as List) {
      if (row is! Map ||
          !scope.contains(row['store_id']) ||
          result.containsKey(row['store_id']) ||
          excluded.contains(row['store_id'])) {
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
