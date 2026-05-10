import 'package:excel/excel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../main.dart';

class DailyRevenue {
  const DailyRevenue({
    required this.date,
    required this.dineIn,
    required this.delivery,
    required this.total,
    this.cashAmount = 0,
    this.cardAmount = 0,
    this.payAmount = 0,
  });

  final DateTime date;
  final double dineIn;
  final double delivery;
  final double total;
  final double cashAmount;
  final double cardAmount;
  final double payAmount;
}

class HourlyRevenue {
  const HourlyRevenue({required this.hour, required this.amount});

  final int hour;
  final double amount;
}

class PaymentMethodBreakdown {
  const PaymentMethodBreakdown({
    required this.method,
    required this.count,
    required this.totalAmount,
    required this.proofCompletePct,
  });

  final String method;
  final int count;
  final double totalAmount;
  final double proofCompletePct;
}

class ReportSummary {
  const ReportSummary({
    required this.dineInRevenue,
    required this.deliveryRevenue,
    required this.serviceTotal,
    required this.totalRevenue,
    required this.totalOrders,
    required this.completedOrders,
    required this.dailyBreakdown,
    this.cashTotal = 0,
    this.cardTotal = 0,
    this.payTotal = 0,
    this.cancelledOrders = 0,
    this.cancelledItems = 0,
    this.hourlyBreakdown = const [],
    this.missingProofPhotosCount = 0,
    this.failedEinvoiceJobsCount = 0,
    this.wetaxReportedCount = 0,
    this.wt08ComparablePosCount = 0,
    this.proofCompletePercent = 100,
    this.paymentMethodBreakdown = const [],
  });

  final double dineInRevenue;
  final double deliveryRevenue;
  final double serviceTotal;
  final double totalRevenue;
  final int totalOrders;
  final int completedOrders;
  final List<DailyRevenue> dailyBreakdown;
  final double cashTotal;
  final double cardTotal;
  final double payTotal;
  final int cancelledOrders;
  final int cancelledItems;
  final List<HourlyRevenue> hourlyBreakdown;
  final int missingProofPhotosCount;
  final int failedEinvoiceJobsCount;
  final int wetaxReportedCount;
  final int wt08ComparablePosCount;
  final double proofCompletePercent;
  final List<PaymentMethodBreakdown> paymentMethodBreakdown;
}

class ReportState {
  const ReportState({
    required this.startDate,
    required this.endDate,
    this.summary,
    this.isLoading = false,
    this.error,
  });

  final DateTime startDate;
  final DateTime endDate;
  final ReportSummary? summary;
  final bool isLoading;
  final String? error;

  ReportState copyWith({
    DateTime? startDate,
    DateTime? endDate,
    ReportSummary? summary,
    bool? isLoading,
    String? error,
    bool clearSummary = false,
    bool clearError = false,
  }) {
    return ReportState(
      startDate: startDate ?? this.startDate,
      endDate: endDate ?? this.endDate,
      summary: clearSummary ? null : (summary ?? this.summary),
      isLoading: isLoading ?? this.isLoading,
      error: clearError ? null : (error ?? this.error),
    );
  }
}

class ReportNotifier extends StateNotifier<ReportState> {
  ReportNotifier()
    : super(
        ReportState(
          startDate: DateTime(
            DateTime.now().year,
            DateTime.now().month,
            DateTime.now().day,
          ),
          endDate: DateTime.now(),
        ),
      );

  Future<void> setDateRange(
    DateTime start,
    DateTime end,
    String storeId,
  ) async {
    final normalizedStart = DateTime(start.year, start.month, start.day);
    final normalizedEnd = DateTime(
      end.year,
      end.month,
      end.day,
      23,
      59,
      59,
      999,
    );
    state = state.copyWith(
      startDate: normalizedStart,
      endDate: normalizedEnd,
      clearError: true,
    );
    await loadReport(storeId);
  }

  Future<void> loadReport(String storeId) async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final startIso = state.startDate.toIso8601String();
      final endIso = state.endDate.toIso8601String();
      final startClosingDate = DateFormat('yyyyMMdd').format(state.startDate);
      final endClosingDate = DateFormat('yyyyMMdd').format(state.endDate);

      final paymentsRevenueResponse = await supabase
          .from('payments')
          .select(
            'amount, method, created_at, proof_required, proof_photo_url, orders(sales_channel)',
          )
          .eq('restaurant_id', storeId)
          .eq('is_revenue', true)
          .gte('created_at', startIso)
          .lte('created_at', endIso);

      final externalSalesResponse = await supabase
          .from('external_sales')
          .select('net_amount, completed_at')
          .eq('restaurant_id', storeId)
          .eq('is_revenue', true)
          .eq('order_status', 'completed')
          .gte('completed_at', startIso)
          .lte('completed_at', endIso);

      final servicePaymentsResponse = await supabase
          .from('payments')
          .select('amount')
          .eq('restaurant_id', storeId)
          .eq('is_revenue', false)
          .gte('created_at', startIso)
          .lte('created_at', endIso);

      final ordersResponse = await supabase
          .from('orders')
          .select('id, status, created_at')
          .eq('restaurant_id', storeId)
          .gte('created_at', startIso)
          .lte('created_at', endIso);

      // Cancelled items count
      final cancelledItemsResponse = await supabase
          .from('order_items')
          .select('id, order_id, orders!inner(restaurant_id, created_at)')
          .eq('status', 'cancelled')
          .eq('orders.restaurant_id', storeId)
          .gte('orders.created_at', startIso)
          .lte('orders.created_at', endIso);

      final einvoiceJobsResponse = await supabase
          .from('einvoice_jobs')
          .select(
            'id, status, error_classification, created_at, orders!inner(restaurant_id)',
          )
          .eq('orders.restaurant_id', storeId)
          .gte('created_at', startIso)
          .lte('created_at', endIso);

      final wt08AuditResponse = await supabase
          .from('audit_logs')
          .select('created_at, entity_id, details')
          .eq('action', 'wetax_daily_close')
          .eq('entity_type', 'restaurants')
          .eq('entity_id', storeId)
          .order('created_at', ascending: false);

      double dineInRevenue = 0;
      double cashTotal = 0;
      double cardTotal = 0;
      double payTotal = 0;
      final dailyMap = <String, _DailyAccumulator>{};
      final hourlyMap = <int, double>{};
      final methodMap = <String, _PaymentMethodAccumulator>{};
      var proofRequiredCount = 0;
      var missingProofPhotosCount = 0;

      for (final row in paymentsRevenueResponse) {
        final payment = Map<String, dynamic>.from(row);
        final amount = _toDouble(payment['amount']);
        final method = (payment['method']?.toString() ?? '').toLowerCase();
        final createdAt =
            _parseDateTime(payment['created_at']) ?? state.startDate;
        final dateKey = DateFormat('yyyy-MM-dd').format(createdAt);
        final accumulator = dailyMap.putIfAbsent(
          dateKey,
          () => _DailyAccumulator(
            date: DateTime(createdAt.year, createdAt.month, createdAt.day),
          ),
        );

        // Hourly aggregation
        hourlyMap[createdAt.hour] = (hourlyMap[createdAt.hour] ?? 0) + amount;

        if (payment['proof_required'] == true) {
          proofRequiredCount += 1;
          final proofUrl = payment['proof_photo_url']?.toString() ?? '';
          if (proofUrl.trim().isEmpty) {
            missingProofPhotosCount += 1;
          }
        }

        final methodLabel = _paymentMethodLabel(method);
        final methodAccumulator = methodMap.putIfAbsent(
          methodLabel,
          () => _PaymentMethodAccumulator(method: methodLabel),
        );
        methodAccumulator.count += 1;
        methodAccumulator.totalAmount += amount;
        if (payment['proof_required'] == true) {
          methodAccumulator.proofRequired += 1;
          final proofUrl = payment['proof_photo_url']?.toString() ?? '';
          if (proofUrl.trim().isNotEmpty) {
            methodAccumulator.proofCompleted += 1;
          }
        }

        // Payment method aggregation
        switch (method) {
          case 'cash':
            cashTotal += amount;
            accumulator.cash += amount;
          case 'creditcard':
          case 'atm':
          case 'banktransfer':
            cardTotal += amount;
            accumulator.card += amount;
          case 'momo':
          case 'zalopay':
          case 'vnpay':
          case 'shopeepay':
          case 'voucher':
          case 'creditsale':
          case 'other':
            payTotal += amount;
            accumulator.pay += amount;
        }

        String channel = '';
        final orderRaw = payment['orders'];
        if (orderRaw is Map<String, dynamic>) {
          channel = orderRaw['sales_channel']?.toString() ?? '';
        }
        final normalized = channel.toLowerCase();
        if (normalized == 'delivery') {
          accumulator.delivery += amount;
        } else {
          accumulator.dineIn += amount;
          dineInRevenue += amount;
        }
      }

      double deliveryRevenue = 0;
      for (final row in externalSalesResponse) {
        final external = Map<String, dynamic>.from(row);
        final amount = _toDouble(external['net_amount']);
        final completedAt =
            _parseDateTime(external['completed_at']) ?? state.startDate;
        final dateKey = DateFormat('yyyy-MM-dd').format(completedAt);
        final accumulator = dailyMap.putIfAbsent(
          dateKey,
          () => _DailyAccumulator(
            date: DateTime(
              completedAt.year,
              completedAt.month,
              completedAt.day,
            ),
          ),
        );
        accumulator.delivery += amount;
        deliveryRevenue += amount;
      }

      double serviceTotal = 0;
      for (final row in servicePaymentsResponse) {
        final payment = Map<String, dynamic>.from(row);
        serviceTotal += _toDouble(payment['amount']);
      }

      final totalOrders = ordersResponse.length;
      final completedOrders = ordersResponse
          .where(
            (order) => order['status']?.toString().toLowerCase() == 'completed',
          )
          .length;
      final cancelledOrders = ordersResponse
          .where(
            (order) => order['status']?.toString().toLowerCase() == 'cancelled',
          )
          .length;
      final cancelledItems = cancelledItemsResponse.length;
      final failedEinvoiceJobsCount = einvoiceJobsResponse.where((row) {
        final job = Map<String, dynamic>.from(row);
        final status = job['status']?.toString();
        final errClass = job['error_classification']?.toString() ?? '';
        return (status == 'failed_terminal' || status == 'stale') &&
            errClass != 'manual_resolved' &&
            errClass != 'duplicate_resolved';
      }).length;
      final wt08LogsByCloseKey = <String, Map<String, dynamic>>{};
      final successfulClosingDates = <String>{};
      for (final row in wt08AuditResponse) {
        final log = Map<String, dynamic>.from(row);
        final detailsRaw = log['details'];
        if (detailsRaw is! Map) continue;
        final details = Map<String, dynamic>.from(detailsRaw);
        if (details['success'] != true) continue;
        final closingDate = details['closing_date']?.toString() ?? '';
        if (closingDate.isEmpty) continue;
        if (closingDate.compareTo(startClosingDate) < 0 ||
            closingDate.compareTo(endClosingDate) > 0) {
          continue;
        }
        final logStoreId =
            details['store_id']?.toString() ??
            log['entity_id']?.toString() ??
            '';
        final closeKey = '$logStoreId:$closingDate';
        if (!wt08LogsByCloseKey.containsKey(closeKey)) {
          wt08LogsByCloseKey[closeKey] = log;
          successfulClosingDates.add(closingDate);
        }
      }
      final wetaxReportedCount = wt08LogsByCloseKey.values.fold<int>(0, (
        sum,
        log,
      ) {
        final details = Map<String, dynamic>.from(
          log['details'] as Map<String, dynamic>,
        );
        return sum + _toDouble(details['total_order_count']).round();
      });
      final wt08ComparablePosCount = ordersResponse.where((order) {
        if (order['status']?.toString().toLowerCase() != 'completed') {
          return false;
        }
        final createdAt = _parseDateTime(order['created_at']);
        if (createdAt == null) return false;
        final orderDate = DateFormat('yyyyMMdd').format(createdAt.toLocal());
        return successfulClosingDates.contains(orderDate);
      }).length;
      final proofCompletePercent = proofRequiredCount == 0
          ? 100.0
          : ((proofRequiredCount - missingProofPhotosCount) /
                    proofRequiredCount) *
                100;

      final hourlyBreakdown =
          hourlyMap.entries
              .map((e) => HourlyRevenue(hour: e.key, amount: e.value))
              .toList()
            ..sort((a, b) => a.hour.compareTo(b.hour));
      final paymentMethodBreakdown =
          methodMap.values.map((method) => method.toBreakdown()).toList()
            ..sort((a, b) => a.method.compareTo(b.method));

      final breakdown =
          dailyMap.values
              .map(
                (day) => DailyRevenue(
                  date: day.date,
                  dineIn: day.dineIn,
                  delivery: day.delivery,
                  total: day.dineIn + day.delivery,
                  cashAmount: day.cash,
                  cardAmount: day.card,
                  payAmount: day.pay,
                ),
              )
              .toList()
            ..sort((a, b) => a.date.compareTo(b.date));

      final summary = ReportSummary(
        dineInRevenue: dineInRevenue,
        deliveryRevenue: deliveryRevenue,
        serviceTotal: serviceTotal,
        totalRevenue: dineInRevenue + deliveryRevenue,
        totalOrders: totalOrders,
        completedOrders: completedOrders,
        dailyBreakdown: breakdown,
        cashTotal: cashTotal,
        cardTotal: cardTotal,
        payTotal: payTotal,
        cancelledOrders: cancelledOrders,
        cancelledItems: cancelledItems,
        hourlyBreakdown: hourlyBreakdown,
        missingProofPhotosCount: missingProofPhotosCount,
        failedEinvoiceJobsCount: failedEinvoiceJobsCount,
        wetaxReportedCount: wetaxReportedCount,
        wt08ComparablePosCount: wt08ComparablePosCount,
        proofCompletePercent: proofCompletePercent,
        paymentMethodBreakdown: paymentMethodBreakdown,
      );

      state = state.copyWith(
        summary: summary,
        isLoading: false,
        clearError: true,
      );
    } catch (error) {
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load report: $error',
      );
    }
  }

  List<int> exportToExcel() {
    final summary = state.summary;
    if (summary == null) return <int>[];

    final dateFormat = DateFormat('dd/MM/yyyy');
    final excel = Excel.createExcel();
    final sheet = excel['Sales Report'];

    // Title
    sheet.appendRow([
      TextCellValue(
        'GLOBOS Sales Report ${dateFormat.format(state.startDate)} ~ ${dateFormat.format(state.endDate)}',
      ),
    ]);
    sheet.appendRow([TextCellValue('')]);

    // Summary section
    sheet.appendRow([TextCellValue('Summary')]);
    sheet.appendRow([
      TextCellValue('Store Revenue'),
      DoubleCellValue(summary.dineInRevenue),
    ]);
    sheet.appendRow([
      TextCellValue('Delivery Revenue'),
      DoubleCellValue(summary.deliveryRevenue),
    ]);
    sheet.appendRow([
      TextCellValue('Total Revenue'),
      DoubleCellValue(summary.totalRevenue),
    ]);
    sheet.appendRow([
      TextCellValue('Service Expenses'),
      DoubleCellValue(summary.serviceTotal),
    ]);
    sheet.appendRow([
      TextCellValue('Missing Proof Photos'),
      IntCellValue(summary.missingProofPhotosCount),
    ]);
    sheet.appendRow([
      TextCellValue('Failed E-Invoice Jobs'),
      IntCellValue(summary.failedEinvoiceJobsCount),
    ]);
    sheet.appendRow([
      TextCellValue('WT08 Reported'),
      IntCellValue(summary.wetaxReportedCount),
    ]);
    sheet.appendRow([
      TextCellValue('WT08 Comparable POS Orders'),
      IntCellValue(summary.wt08ComparablePosCount),
    ]);
    sheet.appendRow([TextCellValue('')]);

    // Payment method breakdown
    sheet.appendRow([TextCellValue('By Payment Method')]);
    sheet.appendRow([
      TextCellValue('Method'),
      TextCellValue('Count'),
      TextCellValue('Total Amount'),
      TextCellValue('proof_complete_pct'),
    ]);
    for (final method in summary.paymentMethodBreakdown) {
      sheet.appendRow([
        TextCellValue(method.method),
        IntCellValue(method.count),
        DoubleCellValue(method.totalAmount),
        DoubleCellValue(method.proofCompletePct),
      ]);
    }
    sheet.appendRow([TextCellValue('')]);

    // Order counts
    sheet.appendRow([TextCellValue('Order Status')]);
    sheet.appendRow([
      TextCellValue('Total Orders'),
      IntCellValue(summary.totalOrders),
    ]);
    sheet.appendRow([
      TextCellValue('Done'),
      IntCellValue(summary.completedOrders),
    ]);
    sheet.appendRow([
      TextCellValue('Cancelled Orders'),
      IntCellValue(summary.cancelledOrders),
    ]);
    sheet.appendRow([
      TextCellValue('Cancelled Items'),
      IntCellValue(summary.cancelledItems),
    ]);
    sheet.appendRow([TextCellValue('')]);

    // Daily breakdown
    sheet.appendRow([TextCellValue('Daily Details')]);
    sheet.appendRow([
      TextCellValue('Date'),
      TextCellValue('Store'),
      TextCellValue('Delivery'),
      TextCellValue('Total'),
      TextCellValue('Cash'),
      TextCellValue('Card'),
      TextCellValue('Pay'),
    ]);

    for (final day in summary.dailyBreakdown) {
      sheet.appendRow([
        TextCellValue(DateFormat('dd/MM').format(day.date)),
        DoubleCellValue(day.dineIn),
        DoubleCellValue(day.delivery),
        DoubleCellValue(day.total),
        DoubleCellValue(day.cashAmount),
        DoubleCellValue(day.cardAmount),
        DoubleCellValue(day.payAmount),
      ]);
    }

    // Totals row
    sheet.appendRow([
      TextCellValue('Total'),
      DoubleCellValue(summary.dineInRevenue),
      DoubleCellValue(summary.deliveryRevenue),
      DoubleCellValue(summary.totalRevenue),
      DoubleCellValue(summary.cashTotal),
      DoubleCellValue(summary.cardTotal),
      DoubleCellValue(summary.payTotal),
    ]);

    final bytes = excel.encode();
    return bytes ?? <int>[];
  }
}

double _toDouble(dynamic value) {
  return switch (value) {
    num v => v.toDouble(),
    String v => double.tryParse(v) ?? 0,
    _ => 0,
  };
}

DateTime? _parseDateTime(dynamic value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}

class _DailyAccumulator {
  _DailyAccumulator({required this.date});

  final DateTime date;
  double dineIn = 0;
  double delivery = 0;
  double cash = 0;
  double card = 0;
  double pay = 0;
}

class _PaymentMethodAccumulator {
  _PaymentMethodAccumulator({required this.method});

  final String method;
  int count = 0;
  double totalAmount = 0;
  int proofRequired = 0;
  int proofCompleted = 0;

  PaymentMethodBreakdown toBreakdown() {
    final proofCompletePct = proofRequired == 0
        ? 100.0
        : (proofCompleted / proofRequired) * 100;
    return PaymentMethodBreakdown(
      method: method,
      count: count,
      totalAmount: totalAmount,
      proofCompletePct: proofCompletePct,
    );
  }
}

String _paymentMethodLabel(String method) {
  return switch (method) {
    'cash' => 'CASH',
    'creditcard' || 'atm' || 'banktransfer' => 'CARD',
    'momo' ||
    'zalopay' ||
    'vnpay' ||
    'shopeepay' ||
    'voucher' ||
    'creditsale' ||
    'other' => 'PAY',
    _ => method.toUpperCase(),
  };
}

final reportProvider = StateNotifierProvider<ReportNotifier, ReportState>(
  (ref) => ReportNotifier(),
);
