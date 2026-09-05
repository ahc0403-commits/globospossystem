// Frozen phase-1C arithmetic. Used only for differential SQL regression tests.
import 'package:intl/intl.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';
import 'package:globos_pos_system/core/payments/payment_method_contract.dart';

ReportSummary legacyReportSummary({
  required DateTime requestedStart,
  required List<Map<String, dynamic>> paymentsRevenueResponse,
  required List<Map<String, dynamic>> externalSalesResponse,
  required List<Map<String, dynamic>> photoObjetSalesResponse,
  required List<Map<String, dynamic>> servicePaymentsResponse,
  required List<Map<String, dynamic>> ordersResponse,
  required Object? cancelledAmountResponse,
  required List<Map<String, dynamic>> cancelledItemsResponse,
  required List<Map<String, dynamic>> einvoiceJobsResponse,
}) {
  double dineInRevenue = 0;
  double deliveryRevenue = 0;
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
    final salesAmount = revenuePaymentSalesAmount(payment);
    final normalizedMethod = normalizePaymentMethodInput(
      payment['method']?.toString() ?? '',
    );
    final method = normalizedMethod.isEmpty ? 'UNKNOWN' : normalizedMethod;
    final parsedCreatedAt = _parseDateTime(payment['created_at']);
    final createdAt = parsedCreatedAt == null
        ? requestedStart
        : toHoChiMinhBusinessTime(parsedCreatedAt);
    final dateKey = DateFormat('yyyy-MM-dd').format(createdAt);
    final accumulator = dailyMap.putIfAbsent(
      dateKey,
      () => _DailyAccumulator(
        date: DateTime(createdAt.year, createdAt.month, createdAt.day),
      ),
    );

    // Hourly aggregation
    hourlyMap[createdAt.hour] = (hourlyMap[createdAt.hour] ?? 0) + salesAmount;

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
      deliveryRevenue += salesAmount;
    } else {
      accumulator.teamKeys.add(transactionKey);
      accumulator.dineIn += salesAmount;
      dineInRevenue += salesAmount;
    }
  }

  for (final row in externalSalesResponse) {
    final external = Map<String, dynamic>.from(row);
    final amount = _toDouble(external['net_amount']);
    final parsedCompletedAt = _parseDateTime(external['completed_at']);
    final completedAt = parsedCompletedAt == null
        ? requestedStart
        : toHoChiMinhBusinessTime(parsedCompletedAt);
    final dateKey = DateFormat('yyyy-MM-dd').format(completedAt);
    final accumulator = dailyMap.putIfAbsent(
      dateKey,
      () => _DailyAccumulator(
        date: DateTime(completedAt.year, completedAt.month, completedAt.day),
      ),
    );
    hourlyMap[completedAt.hour] = (hourlyMap[completedAt.hour] ?? 0) + amount;
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
            (order) => order['status']?.toString().toLowerCase() == 'completed',
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
  final missingProofIssues = collectMissingProofIssues(revenuePayments);
  missingProofPhotosCount = missingProofIssues.length;
  final paymentIdByOrderId = <String, String>{
    for (final payment in revenuePayments)
      if ((payment['order_id']?.toString() ?? '').isNotEmpty &&
          (payment['id']?.toString() ?? '').isNotEmpty)
        payment['order_id'].toString(): payment['id'].toString(),
  };
  final einvoiceReviewIssues = collectEinvoiceReviewIssues(
    List<Map<String, dynamic>>.from(einvoiceJobsResponse),
    paymentIdByOrderId: paymentIdByOrderId,
  );
  final failedEinvoiceJobsCount = einvoiceReviewIssues.length;
  final proofCompletePercent = proofRequiredCount == 0
      ? 100.0
      : ((proofRequiredCount - missingProofPhotosCount) / proofRequiredCount) *
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

  return ReportSummary(
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
    proofCompletePercent: proofCompletePercent,
    paymentMethodBreakdown: paymentMethodBreakdown,
    missingProofIssues: missingProofIssues,
    einvoiceReviewIssues: einvoiceReviewIssues,
  );
}

double _toDouble(dynamic value) {
  return switch (value) {
    num v => v.toDouble(),
    String v => double.tryParse(v) ?? 0,
    _ => 0,
  };
}

/// Sales allocation is independent of received cash. Only legacy null values
/// fall back to amount; a zero allocation remains zero.
double revenuePaymentSalesAmount(Map<String, dynamic> payment) {
  final amountPortion = payment['amount_portion'];
  return amountPortion == null
      ? _toDouble(payment['amount'])
      : _toDouble(amountPortion);
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
  double bankTransfer = 0;
  double pay = 0;
  double paymentSales = 0;
  double paymentReceived = 0;
  final Set<String> teamKeys = <String>{};
  int supplementalTeamCount = 0;
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
