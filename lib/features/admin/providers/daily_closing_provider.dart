import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/services/daily_closing_service.dart';

class DailyClosingRecord {
  const DailyClosingRecord({
    required this.id,
    required this.closingDate,
    required this.closedByName,
    required this.ordersTotal,
    required this.ordersCompleted,
    required this.ordersCancelled,
    required this.itemsCancelled,
    required this.paymentsCount,
    required this.paymentsTotal,
    required this.paymentsCash,
    required this.paymentsCard,
    required this.paymentsPay,
    required this.serviceCount,
    required this.serviceTotal,
    required this.lowStockCount,
    this.notes,
    required this.createdAt,
  });

  final String id;
  final String closingDate;
  final String closedByName;
  final int ordersTotal;
  final int ordersCompleted;
  final int ordersCancelled;
  final int itemsCancelled;
  final int paymentsCount;
  final double paymentsTotal;
  final double paymentsCash;
  final double paymentsCard;
  final double paymentsPay;
  final int serviceCount;
  final double serviceTotal;
  final int lowStockCount;
  final String? notes;
  final DateTime createdAt;

  factory DailyClosingRecord.fromJson(Map<String, dynamic> json) {
    return DailyClosingRecord(
      id: json['closing_id']?.toString() ?? '',
      closingDate: json['closing_date']?.toString() ?? '',
      closedByName: json['closed_by_name']?.toString() ?? 'Unknown',
      ordersTotal: _toInt(json['orders_total']),
      ordersCompleted: _toInt(json['orders_completed']),
      ordersCancelled: _toInt(json['orders_cancelled']),
      itemsCancelled: _toInt(json['items_cancelled']),
      paymentsCount: _toInt(json['payments_count']),
      paymentsTotal: _toDouble(json['payments_total']),
      paymentsCash: _toDouble(json['payments_cash']),
      paymentsCard: _toDouble(json['payments_card']),
      paymentsPay: _toDouble(json['payments_pay']),
      serviceCount: _toInt(json['service_count']),
      serviceTotal: _toDouble(json['service_total']),
      lowStockCount: _toInt(json['low_stock_count']),
      notes: json['notes']?.toString(),
      createdAt: DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
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

String mapDailyClosingError(Object error) {
  if (error is! PostgrestException) {
    return 'An error occurred while closing.';
  }

  final message = error.message;
  if (message.contains('DAILY_CLOSING_ALREADY_EXISTS')) {
    return "Today's closing is already complete.";
  }
  if (message.contains('DAILY_CLOSING_FORBIDDEN')) {
    return 'No permission to perform closing.';
  }
  if (message.contains('DAILY_CLOSING_RESTAURANT_REQUIRED')) {
    return 'Cannot close without store info.';
  }
  if (message.contains('DAILY_CLOSINGS_FORBIDDEN')) {
    return 'No permission to view closing history.';
  }

  return 'An error occurred while closing.';
}

final dailyClosingHistoryProvider = FutureProvider.autoDispose
    .family<List<DailyClosingRecord>, String>((ref, storeId) async {
      final rows = await dailyClosingService.fetchDailyClosings(
        storeId: storeId,
      );
      return rows.map(DailyClosingRecord.fromJson).toList();
    });
