import 'dart:convert';

import 'package:supabase_flutter/supabase_flutter.dart';

enum FinancialInputSource {
  staff,
  allowances,
  holidays,
  revenuePayments,
  externalSales,
  photoSales,
  servicePayments,
  orders,
  cancelledItems,
  einvoiceJobs,
}

/// Complete, scoped inputs for existing payroll/report arithmetic.
/// A failed page never exposes partial rows to a caller.
class FinancialInputService {
  const FinancialInputService(this.client);

  final SupabaseClient client;

  Future<List<Map<String, dynamic>>> fetch({
    required FinancialInputSource source,
    List<String> storeIds = const [],
    DateTime? from,
    DateTime? toExclusive,
    String? fromDate,
    String? toDate,
  }) async {
    final scope = List<String>.unmodifiable(storeIds);
    final params = <String, dynamic>{
      'p_source': source.name,
      'p_store_ids': scope,
      'p_from': from?.toUtc().toIso8601String(),
      'p_to': toExclusive?.toUtc().toIso8601String(),
      'p_from_date': fromDate,
      'p_to_date': toDate,
      'p_page_size': 500,
    };
    final rows = <Map<String, dynamic>>[];
    final seen = <String>{};
    List<dynamic>? cursor;
    String? revision;
    int? totalCount;

    while (true) {
      final response = await client.rpc(
        'get_financial_input_page',
        params: {
          ...params,
          'p_cursor': cursor,
          'p_expected_revision': revision,
        },
      );
      if (response is! Map ||
          response['rows'] is! List ||
          response['has_more'] is! bool ||
          response['revision'] is! String ||
          !RegExp(r'^[0-9a-f]{32}$').hasMatch(response['revision'] as String)) {
        throw const FormatException('FINANCIAL_INPUT_RESPONSE_INVALID');
      }
      final pageRevision = response['revision'] as String;
      if (revision != null && revision != pageRevision) {
        throw StateError('FINANCIAL_INPUT_CHANGED');
      }
      revision = pageRevision;
      final count = response['total_count'];
      if (totalCount == null) {
        if (count is! int || count < 0) {
          throw const FormatException('FINANCIAL_INPUT_COUNT_INVALID');
        }
        totalCount = count;
      } else if (count != null && count != totalCount) {
        throw StateError('FINANCIAL_INPUT_CHANGED');
      }
      final page = List<Map<String, dynamic>>.from(response['rows'] as List);
      if (page.length > 500) {
        throw const FormatException('FINANCIAL_INPUT_PAGE_INVALID');
      }
      for (final raw in page) {
        final row = Map<String, dynamic>.from(raw);
        final next = row.remove('_cursor');
        final rowStore = row['store_id'] ?? row['restaurant_id'];
        if (next is! List ||
            next.isEmpty ||
            next.any((value) => value is! String || value.isEmpty) ||
            !seen.add(jsonEncode(next)) ||
            (source != FinancialInputSource.holidays &&
                !scope.contains(rowStore))) {
          throw const FormatException('FINANCIAL_INPUT_PAGE_INVALID');
        }
        cursor = List<dynamic>.from(next);
        rows.add(row);
      }
      if (rows.length > totalCount) throw StateError('FINANCIAL_INPUT_CHANGED');
      if (response['has_more'] == false) {
        if (count == null || rows.length != totalCount) {
          throw const FormatException('FINANCIAL_INPUT_INCOMPLETE');
        }
        return rows;
      }
      if (page.isEmpty) {
        throw const FormatException('FINANCIAL_INPUT_CURSOR_STALLED');
      }
    }
  }
}
