import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';
import 'report_provider.dart';

typedef RevenueHistoryRange = ({String storeId, DateTime start, DateTime end});

final revenueHistoryProvider = FutureProvider.autoDispose
    .family<List<DailyRevenue>, RevenueHistoryRange>((ref, range) {
      return loadRevenueHistory(supabase, range);
    });

/// Only the preceding days required by the moving average. Selected-period
/// totals, other report metrics and exports never consume these rows.
Future<List<DailyRevenue>> loadRevenueHistory(
  SupabaseClient client,
  RevenueHistoryRange range,
) async {
  if (range.end.isBefore(range.start)) return const [];
  final startDate = DateFormat('yyyy-MM-dd').format(range.start);
  final endDate = DateFormat('yyyy-MM-dd').format(range.end);
  // Reuse the report's single-snapshot server aggregate and its sales rules.
  // The scalar JSON response is not truncated by PostgREST's outer row limit.
  final response = await client.rpc(
    'get_store_report_summary',
    params: {
      'p_store_id': range.storeId,
      'p_from_date': startDate,
      'p_to_date': endDate,
    },
  );
  if (response is! Map ||
      response['version'] != 1 ||
      response['store_id'] != range.storeId ||
      response['from_date'] != startDate ||
      response['to_date'] != endDate) {
    throw const FormatException('REVENUE_HISTORY_RESPONSE_INVALID');
  }
  return ReportSummary.fromServer(
    Map<String, dynamic>.from(response),
  ).dailyBreakdown;
}
