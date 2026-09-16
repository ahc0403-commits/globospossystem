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
    required this.paymentsBankTransfer,
    required this.deliveryCashPayout,
    required this.openingCashAmount,
    required this.expectedCashAmount,
    required this.countedCashAmount,
    required this.cashVariance,
    required this.serviceCount,
    required this.serviceTotal,
    required this.lowStockCount,
    required this.closeSource,
    this.snapshotPaymentsTotal = 0,
    this.ledgerPaymentsCount = 0,
    this.ledgerPaymentsTotal = 0,
    this.ledgerPaymentsCash = 0,
    this.ledgerPaymentsCard = 0,
    this.ledgerPaymentsPay = 0,
    this.ledgerPaymentsBankTransfer = 0,
    this.reconciliationDelta = 0,
    this.ledgerAsOf,
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
  final double paymentsBankTransfer;
  final double deliveryCashPayout;
  final double openingCashAmount;
  final double expectedCashAmount;
  final double countedCashAmount;
  final double cashVariance;
  final int serviceCount;
  final double serviceTotal;
  final int lowStockCount;
  final String? closeSource;
  final double snapshotPaymentsTotal;
  final int ledgerPaymentsCount;
  final double ledgerPaymentsTotal;
  final double ledgerPaymentsCash;
  final double ledgerPaymentsCard;
  final double ledgerPaymentsPay;
  final double ledgerPaymentsBankTransfer;
  final double reconciliationDelta;
  final DateTime? ledgerAsOf;
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
      paymentsBankTransfer: _toDouble(json['payments_bank_transfer']),
      deliveryCashPayout: _toDouble(json['delivery_cash_payout']),
      openingCashAmount: _toDouble(json['opening_cash_amount']),
      expectedCashAmount: _toDouble(json['expected_cash_amount']),
      countedCashAmount: _toDouble(json['counted_cash_amount']),
      cashVariance: _toDouble(json['cash_variance']),
      serviceCount: _toInt(json['service_count']),
      serviceTotal: _toDouble(json['service_total']),
      lowStockCount: _toInt(json['low_stock_count']),
      closeSource: json['close_source']?.toString(),
      snapshotPaymentsTotal: _toDouble(json['snapshot_payments_total']),
      ledgerPaymentsCount: _toInt(
        json['ledger_payments_count'] ?? json['payments_count'],
      ),
      ledgerPaymentsTotal: _toDouble(
        json['ledger_payments_total'] ?? json['payments_total'],
      ),
      ledgerPaymentsCash: _toDouble(
        json['ledger_payments_cash'] ?? json['payments_cash'],
      ),
      ledgerPaymentsCard: _toDouble(
        json['ledger_payments_card'] ?? json['payments_card'],
      ),
      ledgerPaymentsPay: _toDouble(
        json['ledger_payments_pay'] ?? json['payments_pay'],
      ),
      ledgerPaymentsBankTransfer: _toDouble(
        json['ledger_payments_bank_transfer'] ?? json['payments_bank_transfer'],
      ),
      reconciliationDelta: _toDouble(json['reconciliation_delta']),
      ledgerAsOf: DateTime.tryParse(json['ledger_as_of']?.toString() ?? ''),
      notes: json['notes']?.toString(),
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.now(),
    );
  }

  bool get isClosed => closeSource == 'manual';

  double get depositTotal =>
      isClosed ? countedCashAmount - openingCashAmount : 0;

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
    return 'Closing is already complete for this date.';
  }
  if (message.contains('DAILY_CLOSING_DATE_INVALID')) {
    return 'A future date cannot be closed.';
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
