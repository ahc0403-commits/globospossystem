import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/admin_audit_service.dart';

String mapAdminAuditError(Object error) {
  if (error is! PostgrestException) {
    return 'Failed to load recent changes.';
  }

  final message = error.message;
  if (message.contains('AUDIT_TRACE_RESTAURANT_REQUIRED')) {
    return 'Cannot load change history without store info.';
  }
  if (message.contains('AUDIT_TRACE_FORBIDDEN')) {
    return 'No permission to view recent changes.';
  }

  return 'Failed to load recent changes.';
}

final adminAuditTraceProvider = FutureProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, storeId) async {
      return adminAuditService.fetchRecentMutationTrace(
        storeId: storeId,
      );
    });

class TodaySummary {
  const TodaySummary({
    required this.ordersPending,
    required this.ordersConfirmed,
    required this.ordersServing,
    required this.ordersCompleted,
    required this.ordersCancelled,
    required this.ordersTotal,
    required this.itemsCancelled,
    required this.paymentsCount,
    required this.paymentsTotal,
    required this.paymentsCash,
    required this.paymentsCard,
    required this.tablesTotal,
    required this.tablesOccupied,
    required this.lowStockCount,
  });

  final int ordersPending;
  final int ordersConfirmed;
  final int ordersServing;
  final int ordersCompleted;
  final int ordersCancelled;
  final int ordersTotal;
  final int itemsCancelled;
  final int paymentsCount;
  final double paymentsTotal;
  final double paymentsCash;
  final double paymentsCard;
  final int tablesTotal;
  final int tablesOccupied;
  final int lowStockCount;

  factory TodaySummary.fromJson(Map<String, dynamic> json) {
    return TodaySummary(
      ordersPending: _toInt(json['orders_pending']),
      ordersConfirmed: _toInt(json['orders_confirmed']),
      ordersServing: _toInt(json['orders_serving']),
      ordersCompleted: _toInt(json['orders_completed']),
      ordersCancelled: _toInt(json['orders_cancelled']),
      ordersTotal: _toInt(json['orders_total']),
      itemsCancelled: _toInt(json['items_cancelled']),
      paymentsCount: _toInt(json['payments_count']),
      paymentsTotal: _toDouble(json['payments_total']),
      paymentsCash: _toDouble(json['payments_cash']),
      paymentsCard: _toDouble(json['payments_card']),
      tablesTotal: _toInt(json['tables_total']),
      tablesOccupied: _toInt(json['tables_occupied']),
      lowStockCount: _toInt(json['low_stock_count']),
    );
  }

  static int _toInt(dynamic v) => switch (v) {
    int val => val,
    num val => val.toInt(),
    String val => int.tryParse(val) ?? 0,
    _ => 0,
  };

  static double _toDouble(dynamic v) => switch (v) {
    num val => val.toDouble(),
    String val => double.tryParse(val) ?? 0,
    _ => 0,
  };
}

final adminTodaySummaryProvider = FutureProvider.autoDispose
    .family<TodaySummary, String>((ref, storeId) async {
      final json = await adminAuditService.fetchTodaySummary(
        storeId: storeId,
      );
      return TodaySummary.fromJson(json);
    });
