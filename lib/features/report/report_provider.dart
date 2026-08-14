import 'package:excel/excel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../core/payments/payment_method_contract.dart';
import '../../main.dart';
import 'menu_sales_analytics.dart';

class DailyRevenue {
  const DailyRevenue({
    required this.date,
    required this.dineIn,
    required this.delivery,
    required this.total,
    this.teamCount = 0,
    this.cashAmount = 0,
    this.cardAmount = 0,
    this.bankTransferAmount = 0,
    this.payAmount = 0,
    this.paymentVariance = 0,
  });

  final DateTime date;
  final double dineIn;
  final double delivery;
  final double total;
  final int teamCount;
  double get averageTableAmount => teamCount == 0 ? 0 : dineIn / teamCount;
  final double cashAmount;
  final double cardAmount;
  final double bankTransferAmount;
  final double payAmount;
  final double paymentVariance;
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

class PaymentMethodTotals {
  const PaymentMethodTotals({
    required this.cash,
    required this.card,
    required this.bankTransfer,
    required this.ePay,
  });

  final double cash;
  final double card;
  final double bankTransfer;
  final double ePay;

  double get total => cash + card + bankTransfer + ePay;
}

PaymentMethodTotals aggregatePaymentMethodTotals(
  Iterable<Map<String, dynamic>> payments,
) {
  var cash = 0.0;
  var card = 0.0;
  var bankTransfer = 0.0;
  var ePay = 0.0;

  for (final payment in payments) {
    final amount = _toDouble(payment['amount']);
    switch (paymentReportBucket(payment['method']?.toString() ?? '')) {
      case PaymentReportBucket.cash:
        cash += amount;
      case PaymentReportBucket.card:
        card += amount;
      case PaymentReportBucket.bankTransfer:
        bankTransfer += amount;
      case PaymentReportBucket.ePay:
        ePay += amount;
    }
  }

  return PaymentMethodTotals(
    cash: cash,
    card: card,
    bankTransfer: bankTransfer,
    ePay: ePay,
  );
}

String revenuePaymentTransactionKey(
  Map<String, dynamic> payment, {
  required int fallbackIndex,
}) {
  final orderId = payment['order_id']?.toString().trim() ?? '';
  if (orderId.isNotEmpty) return 'order:$orderId';

  final paymentId = payment['id']?.toString().trim() ?? '';
  if (paymentId.isNotEmpty) return 'payment:$paymentId';

  return 'anonymous:$fallbackIndex';
}

int countPaidRevenueOrders(Iterable<Map<String, dynamic>> payments) {
  final keys = <String>{};
  var index = 0;
  for (final payment in payments) {
    keys.add(revenuePaymentTransactionKey(payment, fallbackIndex: index));
    index += 1;
  }
  return keys.length;
}

double aggregateRevenueSalesTotal(Iterable<Map<String, dynamic>> payments) {
  return payments.fold<double>(
    0,
    (sum, payment) => sum + _paymentSalesAmount(payment),
  );
}

class PhotoObjetReportTotals {
  const PhotoObjetReportTotals({
    required this.totalRevenue,
    required this.serviceTotal,
    required this.transactionCount,
    required this.dailyBreakdown,
  });

  final double totalRevenue;
  final double serviceTotal;
  final int transactionCount;
  final List<DailyRevenue> dailyBreakdown;
}

PhotoObjetReportTotals aggregatePhotoObjetReportRows(
  Iterable<Map<String, dynamic>> rows,
) {
  final dailyMap = <String, _PhotoObjetDailyAccumulator>{};
  var totalRevenue = 0.0;
  var serviceTotal = 0.0;
  var transactionCount = 0;

  for (final row in rows) {
    final saleDate = _parseDateTime(row['sale_date']);
    if (saleDate == null) continue;

    final grossSales = _toDouble(row['total_gross_sales']);
    final serviceAmount = _toDouble(row['total_service_amount']);
    final salesRevenue = (grossSales - serviceAmount).clamp(0, double.infinity);
    final transactions = _toInt(row['total_transactions']);
    final date = DateTime(saleDate.year, saleDate.month, saleDate.day);
    final dateKey = DateFormat('yyyy-MM-dd').format(date);
    final accumulator = dailyMap.putIfAbsent(
      dateKey,
      () => _PhotoObjetDailyAccumulator(date: date),
    );

    accumulator.revenue += salesRevenue;
    accumulator.teamCount += transactions;
    totalRevenue += salesRevenue;
    serviceTotal += serviceAmount;
    transactionCount += transactions;
  }

  final dailyBreakdown =
      dailyMap.values
          .map(
            (day) => DailyRevenue(
              date: day.date,
              dineIn: day.revenue,
              delivery: 0,
              total: day.revenue,
              teamCount: day.teamCount,
            ),
          )
          .toList()
        ..sort((a, b) => a.date.compareTo(b.date));

  return PhotoObjetReportTotals(
    totalRevenue: totalRevenue,
    serviceTotal: serviceTotal,
    transactionCount: transactionCount,
    dailyBreakdown: dailyBreakdown,
  );
}

class ReportSummary {
  const ReportSummary({
    required this.dineInRevenue,
    required this.deliveryRevenue,
    required this.serviceTotal,
    required this.totalRevenue,
    this.cancelledAmount = 0,
    required this.totalOrders,
    required this.completedOrders,
    required this.paidOrders,
    required this.openOrders,
    required this.dailyBreakdown,
    this.cashTotal = 0,
    this.cardTotal = 0,
    this.bankTransferTotal = 0,
    this.payTotal = 0,
    this.paymentReceivedTotal = 0,
    this.paymentVariance = 0,
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
  final double cancelledAmount;
  double get grossOrderAmount => totalRevenue + cancelledAmount;
  final int totalOrders;
  final int completedOrders;
  final int paidOrders;
  final int openOrders;
  final List<DailyRevenue> dailyBreakdown;
  final double cashTotal;
  final double cardTotal;
  final double bankTransferTotal;
  final double payTotal;
  final double paymentReceivedTotal;
  final double paymentVariance;
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
      final reportRange = reportUtcRange(state.startDate, state.endDate);
      final startIso = reportRange.startUtc.toIso8601String();
      final endExclusiveIso = reportRange.endExclusiveUtc.toIso8601String();
      final endInclusiveIso = reportRange.endExclusiveUtc
          .subtract(const Duration(microseconds: 1))
          .toIso8601String();
      final startClosingDate = DateFormat('yyyyMMdd').format(state.startDate);
      final endClosingDate = DateFormat('yyyyMMdd').format(state.endDate);
      final startSaleDate = DateFormat('yyyy-MM-dd').format(state.startDate);
      final endSaleDate = DateFormat('yyyy-MM-dd').format(state.endDate);

      final paymentsRevenueResponse = await supabase
          .from('payments')
          .select(
            'id, order_id, amount, amount_portion, method, created_at, proof_required, proof_photo_url, orders(sales_channel)',
          )
          .eq('restaurant_id', storeId)
          .eq('is_revenue', true)
          .gte('created_at', startIso)
          .lt('created_at', endExclusiveIso);

      final externalSalesResponse = await supabase
          .from('external_sales')
          .select('net_amount, completed_at')
          .eq('restaurant_id', storeId)
          .eq('is_revenue', true)
          .eq('order_status', 'completed')
          .gte('completed_at', startIso)
          .lt('completed_at', endExclusiveIso);

      final photoObjetSalesResponse = await supabase
          .from('v_photo_objet_daily_summary')
          .select(
            'sale_date, total_gross_sales, total_transactions, total_service_amount',
          )
          .eq('store_id', storeId)
          .gte('sale_date', startSaleDate)
          .lte('sale_date', endSaleDate);

      final servicePaymentsResponse = await supabase
          .from('payments')
          .select('amount')
          .eq('restaurant_id', storeId)
          .eq('is_revenue', false)
          .gte('created_at', startIso)
          .lt('created_at', endExclusiveIso);

      final ordersResponse = await supabase
          .from('orders')
          .select('id, status, created_at')
          .eq('restaurant_id', storeId)
          .gte('created_at', startIso)
          .lt('created_at', endExclusiveIso);

      final cancelledAmountResponse = await supabase.rpc(
        'get_store_sales_cancellation_total',
        params: {
          'p_store_id': storeId,
          'p_start_at': startIso,
          'p_end_at': endInclusiveIso,
        },
      );

      // Cancelled items count
      final cancelledItemsResponse = await supabase
          .from('order_items')
          .select('id, order_id, orders!inner(restaurant_id, created_at)')
          .eq('status', 'cancelled')
          .eq('orders.restaurant_id', storeId)
          .gte('orders.created_at', startIso)
          .lt('orders.created_at', endExclusiveIso);

      final einvoiceJobsResponse = await supabase
          .from('einvoice_jobs')
          .select(
            'id, status, error_classification, created_at, orders!inner(restaurant_id)',
          )
          .eq('orders.restaurant_id', storeId)
          .gte('created_at', startIso)
          .lt('created_at', endExclusiveIso);

      final wt08AuditResponse = await supabase
          .from('audit_logs')
          .select('created_at, entity_id, details')
          .eq('action', 'wetax_daily_close')
          .eq('entity_type', 'restaurants')
          .eq('entity_id', storeId)
          .order('created_at', ascending: false);

      double dineInRevenue = 0;
      final revenuePayments = List<Map<String, dynamic>>.from(
        paymentsRevenueResponse,
      );
      final paymentTotals = aggregatePaymentMethodTotals(revenuePayments);
      final paymentSalesTotal = aggregateRevenueSalesTotal(revenuePayments);
      final dailyMap = <String, _DailyAccumulator>{};
      final hourlyMap = <int, double>{};
      final methodMap = <String, _PaymentMethodAccumulator>{};
      var proofRequiredCount = 0;
      var missingProofPhotosCount = 0;
      var paymentIndex = 0;

      for (final payment in revenuePayments) {
        final receivedAmount = _toDouble(payment['amount']);
        final salesAmount = _paymentSalesAmount(payment);
        final normalizedMethod = normalizePaymentMethodInput(
          payment['method']?.toString() ?? '',
        );
        final method = normalizedMethod.isEmpty ? 'UNKNOWN' : normalizedMethod;
        final parsedCreatedAt = _parseDateTime(payment['created_at']);
        final createdAt = parsedCreatedAt == null
            ? state.startDate
            : toHoChiMinhBusinessTime(parsedCreatedAt);
        final dateKey = DateFormat('yyyy-MM-dd').format(createdAt);
        final accumulator = dailyMap.putIfAbsent(
          dateKey,
          () => _DailyAccumulator(
            date: DateTime(createdAt.year, createdAt.month, createdAt.day),
          ),
        );

        // Hourly aggregation
        hourlyMap[createdAt.hour] =
            (hourlyMap[createdAt.hour] ?? 0) + salesAmount;

        if (payment['proof_required'] == true) {
          proofRequiredCount += 1;
          final proofUrl = payment['proof_photo_url']?.toString() ?? '';
          if (proofUrl.trim().isEmpty) {
            missingProofPhotosCount += 1;
          }
        }

        final methodLabel = method;
        final methodAccumulator = methodMap.putIfAbsent(
          methodLabel,
          () => _PaymentMethodAccumulator(method: methodLabel),
        );
        final transactionKey = revenuePaymentTransactionKey(
          payment,
          fallbackIndex: paymentIndex,
        );
        paymentIndex += 1;
        methodAccumulator.transactionKeys.add(transactionKey);
        methodAccumulator.totalAmount += receivedAmount;
        if (payment['proof_required'] == true) {
          methodAccumulator.proofRequired += 1;
          final proofUrl = payment['proof_photo_url']?.toString() ?? '';
          if (proofUrl.trim().isNotEmpty) {
            methodAccumulator.proofCompleted += 1;
          }
        }

        // Payment method aggregation
        switch (paymentReportBucket(method)) {
          case PaymentReportBucket.cash:
            accumulator.cash += receivedAmount;
          case PaymentReportBucket.card:
            accumulator.card += receivedAmount;
          case PaymentReportBucket.bankTransfer:
            accumulator.bankTransfer += receivedAmount;
          case PaymentReportBucket.ePay:
            accumulator.pay += receivedAmount;
        }
        accumulator.paymentSales += salesAmount;
        accumulator.paymentReceived += receivedAmount;

        String channel = '';
        final orderRaw = payment['orders'];
        if (orderRaw is Map<String, dynamic>) {
          channel = orderRaw['sales_channel']?.toString() ?? '';
        }
        final normalized = channel.toLowerCase();
        if (normalized == 'delivery') {
          accumulator.delivery += salesAmount;
        } else {
          accumulator.teamKeys.add(transactionKey);
          accumulator.dineIn += salesAmount;
          dineInRevenue += salesAmount;
        }
      }

      double deliveryRevenue = 0;
      for (final row in externalSalesResponse) {
        final external = Map<String, dynamic>.from(row);
        final amount = _toDouble(external['net_amount']);
        final parsedCompletedAt = _parseDateTime(external['completed_at']);
        final completedAt = parsedCompletedAt == null
            ? state.startDate
            : toHoChiMinhBusinessTime(parsedCompletedAt);
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
        hourlyMap[completedAt.hour] =
            (hourlyMap[completedAt.hour] ?? 0) + amount;
        accumulator.delivery += amount;
        deliveryRevenue += amount;
      }

      final photoObjetTotals = aggregatePhotoObjetReportRows(
        List<Map<String, dynamic>>.from(photoObjetSalesResponse),
      );
      dineInRevenue += photoObjetTotals.totalRevenue;
      for (final day in photoObjetTotals.dailyBreakdown) {
        final dateKey = DateFormat('yyyy-MM-dd').format(day.date);
        final accumulator = dailyMap.putIfAbsent(
          dateKey,
          () => _DailyAccumulator(date: day.date),
        );
        accumulator.dineIn += day.total;
        accumulator.supplementalTeamCount += day.teamCount;
      }

      double serviceTotal = 0;
      for (final row in servicePaymentsResponse) {
        final payment = Map<String, dynamic>.from(row);
        serviceTotal += _toDouble(payment['amount']);
      }
      serviceTotal += photoObjetTotals.serviceTotal;

      final totalOrders =
          ordersResponse.length +
          externalSalesResponse.length +
          photoObjetTotals.transactionCount;
      final completedOrders =
          ordersResponse
              .where(
                (order) =>
                    order['status']?.toString().toLowerCase() == 'completed',
              )
              .length +
          externalSalesResponse.length +
          photoObjetTotals.transactionCount;
      final paidOrders =
          countPaidRevenueOrders(revenuePayments) +
          externalSalesResponse.length +
          photoObjetTotals.transactionCount;
      final cancelledOrders = ordersResponse
          .where(
            (order) => order['status']?.toString().toLowerCase() == 'cancelled',
          )
          .length;
      final openOrders = ordersResponse.where((order) {
        final status = order['status']?.toString().toLowerCase();
        return status != 'completed' && status != 'cancelled';
      }).length;
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
        final orderDate = DateFormat(
          'yyyyMMdd',
        ).format(toHoChiMinhBusinessTime(createdAt));
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
                  teamCount: day.teamKeys.length + day.supplementalTeamCount,
                  cashAmount: day.cash,
                  cardAmount: day.card,
                  bankTransferAmount: day.bankTransfer,
                  payAmount: day.pay,
                  paymentVariance: day.paymentReceived - day.paymentSales,
                ),
              )
              .toList()
            ..sort((a, b) => a.date.compareTo(b.date));

      final summary = ReportSummary(
        dineInRevenue: dineInRevenue,
        deliveryRevenue: deliveryRevenue,
        serviceTotal: serviceTotal,
        totalRevenue: dineInRevenue + deliveryRevenue,
        cancelledAmount: _toDouble(cancelledAmountResponse),
        totalOrders: totalOrders,
        completedOrders: completedOrders,
        paidOrders: paidOrders,
        openOrders: openOrders,
        dailyBreakdown: breakdown,
        cashTotal: paymentTotals.cash,
        cardTotal: paymentTotals.card,
        bankTransferTotal: paymentTotals.bankTransfer,
        payTotal: paymentTotals.ePay,
        paymentReceivedTotal: paymentTotals.total,
        paymentVariance: paymentTotals.total - paymentSalesTotal,
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

  List<int> exportToExcel({MenuSalesAnalytics? menuSalesAnalytics}) {
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
      TextCellValue('Store Sales Revenue'),
      DoubleCellValue(summary.dineInRevenue),
    ]);
    sheet.appendRow([
      TextCellValue('Delivery Sales Revenue'),
      DoubleCellValue(summary.deliveryRevenue),
    ]);
    sheet.appendRow([
      TextCellValue('Gross Order Amount'),
      DoubleCellValue(summary.grossOrderAmount),
    ]);
    sheet.appendRow([
      TextCellValue('Cancellation Amount'),
      DoubleCellValue(summary.cancelledAmount),
    ]);
    sheet.appendRow([
      TextCellValue('Net Sales Revenue'),
      DoubleCellValue(summary.totalRevenue),
    ]);
    sheet.appendRow([
      TextCellValue('Payment Received Total'),
      DoubleCellValue(summary.paymentReceivedTotal),
    ]);
    sheet.appendRow([
      TextCellValue('Payment Variance'),
      DoubleCellValue(summary.paymentVariance),
    ]);
    sheet.appendRow([
      TextCellValue('Service Revenue (Coin Payments)'),
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
      TextCellValue('Paid Sales Orders'),
      IntCellValue(summary.paidOrders),
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
      TextCellValue('Sales Total'),
      TextCellValue('Cash'),
      TextCellValue('Card'),
      TextCellValue('Bank Transfer'),
      TextCellValue('Pay'),
      TextCellValue('Payment Variance'),
    ]);

    for (final day in summary.dailyBreakdown) {
      sheet.appendRow([
        TextCellValue(DateFormat('dd/MM').format(day.date)),
        DoubleCellValue(day.dineIn),
        DoubleCellValue(day.delivery),
        DoubleCellValue(day.total),
        DoubleCellValue(day.cashAmount),
        DoubleCellValue(day.cardAmount),
        DoubleCellValue(day.bankTransferAmount),
        DoubleCellValue(day.payAmount),
        DoubleCellValue(day.paymentVariance),
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
      DoubleCellValue(summary.bankTransferTotal),
      DoubleCellValue(summary.payTotal),
      DoubleCellValue(summary.paymentVariance),
    ]);

    if (menuSalesAnalytics != null) {
      final menuSheet = excel['Menu Sales'];
      menuSheet.appendRow([
        TextCellValue(
          'POS menu details only. External delivery, Photo sales, service charges, and non-menu amounts are excluded.',
        ),
      ]);
      menuSheet.appendRow([
        TextCellValue('Period'),
        TextCellValue(
          '${dateFormat.format(state.startDate)} ~ ${dateFormat.format(state.endDate)}',
        ),
      ]);
      menuSheet.appendRow([
        TextCellValue('Unallocated refund/void count'),
        IntCellValue(menuSalesAnalytics.summary.unallocatedAdjustmentCount),
        TextCellValue('Unallocated refund/void amount'),
        DoubleCellValue(menuSalesAnalytics.summary.unallocatedAdjustmentAmount),
      ]);
      menuSheet.appendRow([
        TextCellValue('Combo Quantity Sold'),
        IntCellValue(menuSalesAnalytics.summary.comboSoldQuantity),
        TextCellValue('Combo Menu Sales Amount'),
        DoubleCellValue(menuSalesAnalytics.summary.comboMenuSalesAmount),
      ]);
      final topCombo = menuSalesAnalytics.topCombo;
      menuSheet.appendRow([
        TextCellValue('Top Combo'),
        TextCellValue(topCombo?.displayName ?? ''),
        TextCellValue('Top Combo Sales Amount'),
        DoubleCellValue(topCombo?.menuSalesAmount ?? 0),
      ]);
      menuSheet.appendRow([TextCellValue('')]);
      menuSheet.appendRow([
        TextCellValue('Rank'),
        TextCellValue('Menu'),
        TextCellValue('Quantity Sold'),
        TextCellValue('Orders'),
        TextCellValue('Menu Sales Amount'),
        TextCellValue('Quantity Share (%)'),
        TextCellValue('Revenue Share (%)'),
        TextCellValue('Peak Hour (HCM)'),
        TextCellValue('Dine-in Qty'),
        TextCellValue('Takeaway Qty'),
        TextCellValue('POS Delivery Qty'),
        TextCellValue('Identity Quality'),
        TextCellValue('Name Changed In Period'),
        TextCellValue('Combo'),
      ]);
      final menuRows = menuSalesAnalytics.sortedRows(MenuSalesSort.quantity);
      for (var index = 0; index < menuRows.length; index++) {
        final row = menuRows[index];
        menuSheet.appendRow([
          IntCellValue(index + 1),
          TextCellValue(row.displayName),
          IntCellValue(row.soldQuantity),
          IntCellValue(row.orderCount),
          DoubleCellValue(row.menuSalesAmount),
          DoubleCellValue(row.quantityShare),
          DoubleCellValue(row.revenueShare),
          TextCellValue('${row.peakHour.toString().padLeft(2, '0')}:00'),
          IntCellValue(row.dineInQuantity),
          IntCellValue(row.takeawayQuantity),
          IntCellValue(row.deliveryQuantity),
          TextCellValue(row.identityQuality),
          BoolCellValue(row.nameChangedInPeriod),
          BoolCellValue(row.isCombo),
        ]);
      }

      final hourlySheet = excel['Menu by Hour'];
      hourlySheet.appendRow([
        TextCellValue('Timezone'),
        TextCellValue('Asia/Ho_Chi_Minh'),
        TextCellValue('Time basis'),
        TextCellValue('Last revenue payment per completed POS order'),
      ]);
      hourlySheet.appendRow([
        TextCellValue('Hour'),
        TextCellValue('Quantity Sold'),
        TextCellValue('Menu Sales Amount'),
        TextCellValue('POS Orders'),
      ]);
      for (final hour in menuSalesAnalytics.hourRows) {
        hourlySheet.appendRow([
          TextCellValue('${hour.hour.toString().padLeft(2, '0')}:00'),
          IntCellValue(hour.soldQuantity),
          DoubleCellValue(hour.menuSalesAmount),
          IntCellValue(hour.orderCount),
        ]);
      }
      hourlySheet.appendRow([TextCellValue('')]);
      hourlySheet.appendRow([
        TextCellValue('Top Menu Rank'),
        TextCellValue('Menu'),
        TextCellValue('Hour'),
        TextCellValue('Quantity Sold'),
        TextCellValue('Menu Sales Amount'),
      ]);
      for (final row in menuSalesAnalytics.topMenuHourRows) {
        hourlySheet.appendRow([
          IntCellValue(row.rank),
          TextCellValue(row.displayName),
          TextCellValue('${row.hour.toString().padLeft(2, '0')}:00'),
          IntCellValue(row.soldQuantity),
          DoubleCellValue(row.menuSalesAmount),
        ]);
      }
    }

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

double _paymentSalesAmount(Map<String, dynamic> payment) {
  final amountPortion = payment['amount_portion'];
  return amountPortion == null
      ? _toDouble(payment['amount'])
      : _toDouble(amountPortion);
}

int _toInt(dynamic value) {
  return switch (value) {
    num v => v.toInt(),
    String v => int.tryParse(v) ?? 0,
    _ => 0,
  };
}

DateTime? _parseDateTime(dynamic value) {
  if (value == null) {
    return null;
  }
  return DateTime.tryParse(value.toString());
}

DateTime toHoChiMinhBusinessTime(DateTime timestamp) {
  return timestamp.toUtc().add(const Duration(hours: 7));
}

({DateTime startUtc, DateTime endExclusiveUtc}) reportUtcRange(
  DateTime start,
  DateTime end,
) {
  const offset = Duration(hours: 7);
  final startUtc = DateTime.utc(
    start.year,
    start.month,
    start.day,
  ).subtract(offset);
  final endExclusiveUtc = DateTime.utc(
    end.year,
    end.month,
    end.day + 1,
  ).subtract(offset);
  return (startUtc: startUtc, endExclusiveUtc: endExclusiveUtc);
}

class _DailyAccumulator {
  _DailyAccumulator({required this.date});

  final DateTime date;
  double dineIn = 0;
  double delivery = 0;
  double cash = 0;
  double card = 0;
  double bankTransfer = 0;
  double pay = 0;
  double paymentSales = 0;
  double paymentReceived = 0;
  final Set<String> teamKeys = <String>{};
  int supplementalTeamCount = 0;
}

class _PhotoObjetDailyAccumulator {
  _PhotoObjetDailyAccumulator({required this.date});

  final DateTime date;
  double revenue = 0;
  int teamCount = 0;
}

class _PaymentMethodAccumulator {
  _PaymentMethodAccumulator({required this.method});

  final String method;
  final Set<String> transactionKeys = <String>{};
  double totalAmount = 0;
  int proofRequired = 0;
  int proofCompleted = 0;

  PaymentMethodBreakdown toBreakdown() {
    final proofCompletePct = proofRequired == 0
        ? 100.0
        : (proofCompleted / proofRequired) * 100;
    return PaymentMethodBreakdown(
      method: method,
      count: transactionKeys.length,
      totalAmount: totalAmount,
      proofCompletePct: proofCompletePct,
    );
  }
}

final reportProvider = StateNotifierProvider<ReportNotifier, ReportState>(
  (ref) => ReportNotifier(),
);
