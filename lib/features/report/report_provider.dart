import 'package:excel/excel.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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

class MissingProofIssue {
  const MissingProofIssue({
    required this.paymentId,
    required this.orderId,
    required this.amount,
    required this.method,
    required this.createdAt,
  });

  final String paymentId;
  final String orderId;
  final double amount;
  final String method;
  final DateTime? createdAt;
}

class EinvoiceReviewIssue {
  const EinvoiceReviewIssue({
    required this.jobId,
    required this.orderId,
    required this.paymentId,
    required this.status,
    required this.detail,
    required this.createdAt,
  });

  final String jobId;
  final String orderId;
  final String? paymentId;
  final String status;
  final String detail;
  final DateTime? createdAt;
}

List<MissingProofIssue> collectMissingProofIssues(
  Iterable<Map<String, dynamic>> payments,
) {
  return payments
      .where((payment) {
        if (payment['proof_required'] != true) return false;
        final proofUrl = payment['proof_photo_url']?.toString() ?? '';
        return proofUrl.trim().isEmpty;
      })
      .map((payment) {
        final createdAt = _parseDateTime(payment['created_at']);
        return MissingProofIssue(
          paymentId: payment['id']?.toString() ?? '',
          orderId: payment['order_id']?.toString() ?? '',
          amount: _toDouble(payment['amount']),
          method: normalizePaymentMethodInput(
            payment['method']?.toString() ?? '',
          ),
          createdAt: createdAt == null
              ? null
              : toHoChiMinhBusinessTime(createdAt),
        );
      })
      .where((issue) => issue.paymentId.isNotEmpty)
      .toList(growable: false);
}

List<EinvoiceReviewIssue> collectEinvoiceReviewIssues(
  Iterable<Map<String, dynamic>> jobs, {
  required Map<String, String> paymentIdByOrderId,
}) {
  return jobs
      .where((job) {
        final status = job['status']?.toString() ?? '';
        return status == 'failed' || status == 'manual_action_required';
      })
      .map((job) {
        final orderId = job['order_id']?.toString() ?? '';
        final createdAt = _parseDateTime(job['created_at']);
        final detail =
            job['error_message']?.toString().trim().isNotEmpty == true
            ? job['error_message'].toString().trim()
            : job['manual_action_type']?.toString().trim() ?? '';
        return EinvoiceReviewIssue(
          jobId: job['id']?.toString() ?? '',
          orderId: orderId,
          paymentId: paymentIdByOrderId[orderId],
          status: job['status']?.toString() ?? 'unknown',
          detail: detail,
          createdAt: createdAt == null
              ? null
              : toHoChiMinhBusinessTime(createdAt),
        );
      })
      .where((issue) => issue.jobId.isNotEmpty)
      .toList(growable: false);
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
    (sum, payment) => sum + revenuePaymentSalesAmount(payment),
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
    this.proofCompletePercent = 100,
    this.paymentMethodBreakdown = const [],
    this.missingProofIssues = const [],
    this.einvoiceReviewIssues = const [],
  });

  factory ReportSummary.fromServer(Map<String, dynamic> data) {
    double number(Map row, String key) {
      final value = row[key];
      if (value is! num || !value.isFinite) {
        throw FormatException('STORE_REPORT_NUMBER_INVALID: $key');
      }
      return value.toDouble();
    }

    int integer(Map row, String key) {
      final value = number(row, key);
      if (value != value.truncateToDouble()) {
        throw FormatException('STORE_REPORT_COUNT_INVALID: $key');
      }
      return value.toInt();
    }

    String string(Map row, String key) {
      if (row[key] is! String) {
        throw FormatException('STORE_REPORT_STRING_INVALID: $key');
      }
      return row[key] as String;
    }

    List<Map<String, dynamic>> rows(String key) {
      final value = data[key];
      if (value is! List) {
        throw FormatException('STORE_REPORT_ROWS_INVALID: $key');
      }
      return value.map((row) => Map<String, dynamic>.from(row as Map)).toList();
    }

    final missing = rows('missing_proof')
        .map(
          (r) => MissingProofIssue(
            paymentId: string(r, 'id'),
            orderId: r['order_id']?.toString() ?? '',
            amount: number(r, 'amount'),
            method: string(r, 'method'),
            createdAt: toHoChiMinhBusinessTime(
              DateTime.parse(string(r, 'created_at')),
            ),
          ),
        )
        .toList();
    final jobs = rows('einvoice_issues')
        .map(
          (r) => EinvoiceReviewIssue(
            jobId: string(r, 'id'),
            orderId: r['order_id']?.toString() ?? '',
            paymentId: r['payment_id'] as String?,
            status: string(r, 'status'),
            detail: string(r, 'detail'),
            createdAt: toHoChiMinhBusinessTime(
              DateTime.parse(string(r, 'created_at')),
            ),
          ),
        )
        .toList();
    if (missing.length != integer(data, 'missing_proof_count') ||
        jobs.length != integer(data, 'failed_einvoice_count')) {
      throw const FormatException('STORE_REPORT_ISSUES_INCOMPLETE');
    }
    final dineIn = number(data, 'dine_in');
    final delivery = number(data, 'delivery');
    final cash = number(data, 'cash');
    final card = number(data, 'card');
    final bank = number(data, 'bank');
    final pay = number(data, 'pay');
    return ReportSummary(
      dineInRevenue: dineIn,
      deliveryRevenue: delivery,
      totalRevenue: dineIn + delivery,
      serviceTotal: number(data, 'service'),
      cancelledAmount: number(data, 'cancelled_amount'),
      totalOrders: integer(data, 'total_orders'),
      completedOrders: integer(data, 'completed_orders'),
      paidOrders: integer(data, 'paid_orders'),
      openOrders: integer(data, 'open_orders'),
      cancelledOrders: integer(data, 'cancelled_orders'),
      cancelledItems: integer(data, 'cancelled_items'),
      cashTotal: cash,
      cardTotal: card,
      bankTransferTotal: bank,
      payTotal: pay,
      paymentReceivedTotal: cash + card + bank + pay,
      paymentVariance: number(data, 'variance'),
      missingProofPhotosCount: missing.length,
      failedEinvoiceJobsCount: jobs.length,
      missingProofIssues: missing,
      einvoiceReviewIssues: jobs,
      proofCompletePercent: number(data, 'proof_pct'),
      dailyBreakdown: rows('daily')
          .map(
            (r) => DailyRevenue(
              date: DateTime.parse(string(r, 'date')),
              dineIn: number(r, 'dine_in'),
              delivery: number(r, 'delivery'),
              total: number(r, 'dine_in') + number(r, 'delivery'),
              teamCount: integer(r, 'teams'),
              cashAmount: number(r, 'cash'),
              cardAmount: number(r, 'card'),
              bankTransferAmount: number(r, 'bank'),
              payAmount: number(r, 'pay'),
              paymentVariance: number(r, 'variance'),
            ),
          )
          .toList(),
      hourlyBreakdown: rows('hourly')
          .map(
            (r) => HourlyRevenue(
              hour: integer(r, 'hour'),
              amount: number(r, 'amount'),
            ),
          )
          .toList(),
      paymentMethodBreakdown: rows('methods')
          .map(
            (r) => PaymentMethodBreakdown(
              method: string(r, 'method'),
              count: integer(r, 'count'),
              totalAmount: number(r, 'amount'),
              proofCompletePct: number(r, 'proof_pct'),
            ),
          )
          .toList(),
    );
  }

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
  final double proofCompletePercent;
  final List<PaymentMethodBreakdown> paymentMethodBreakdown;
  final List<MissingProofIssue> missingProofIssues;
  final List<EinvoiceReviewIssue> einvoiceReviewIssues;
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
  ReportNotifier({SupabaseClient? client})
    : _client = client,
      super(
        ReportState(
          startDate: DateTime(
            DateTime.now().year,
            DateTime.now().month,
            DateTime.now().day,
          ),
          endDate: DateTime.now(),
        ),
      );

  final SupabaseClient? _client;
  int _requestId = 0;

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
      clearSummary: true,
      clearError: true,
    );
    await loadReport(storeId);
  }

  Future<void> loadReport(String storeId) async {
    final requestId = ++_requestId;
    final requestedStart = state.startDate;
    final requestedEnd = state.endDate;
    state = state.copyWith(
      isLoading: true,
      clearError: true,
      clearSummary: true,
    );

    try {
      final startDate = DateFormat('yyyy-MM-dd').format(requestedStart);
      final endDate = DateFormat('yyyy-MM-dd').format(requestedEnd);
      final response = await (_client ?? supabase).rpc(
        'get_store_report_summary',
        params: {
          'p_store_id': storeId,
          'p_from_date': startDate,
          'p_to_date': endDate,
        },
      );
      if (!mounted || requestId != _requestId) return;
      if (response is! Map ||
          response['version'] != 1 ||
          response['store_id'] != storeId ||
          response['from_date'] != startDate ||
          response['to_date'] != endDate) {
        throw const FormatException('STORE_REPORT_RESPONSE_INVALID');
      }
      final summary = ReportSummary.fromServer(
        Map<String, dynamic>.from(response),
      );

      state = state.copyWith(
        summary: summary,
        isLoading: false,
        clearError: true,
      );
    } catch (error) {
      if (!mounted || requestId != _requestId) return;
      state = state.copyWith(
        isLoading: false,
        error: 'Failed to load report: $error',
        clearSummary: true,
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

/// Sales allocation is independent of received cash. Only legacy null values
/// fall back to amount; a zero allocation remains zero.
double revenuePaymentSalesAmount(Map<String, dynamic> payment) {
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

class _PhotoObjetDailyAccumulator {
  _PhotoObjetDailyAccumulator({required this.date});

  final DateTime date;
  double revenue = 0;
  int teamCount = 0;
}

final reportProvider = StateNotifierProvider<ReportNotifier, ReportState>(
  (ref) => ReportNotifier(),
);
