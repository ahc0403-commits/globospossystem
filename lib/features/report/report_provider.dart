import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';

import '../../main.dart';

class DailyRevenue {
  const DailyRevenue({
    required this.date,
    required this.dineIn,
    required this.delivery,
    required this.total,
  });

  final DateTime date;
  final double dineIn;
  final double delivery;
  final double total;
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
  });

  final double dineInRevenue;
  final double deliveryRevenue;
  final double serviceTotal;
  final double totalRevenue;
  final int totalOrders;
  final int completedOrders;
  final List<DailyRevenue> dailyBreakdown;
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

  Future<void> setDateRange(DateTime start, DateTime end, String restaurantId) async {
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
    await loadReport(restaurantId);
  }

  Future<void> loadReport(String restaurantId) async {
    state = state.copyWith(isLoading: true, clearError: true);

    try {
      final startIso = state.startDate.toIso8601String();
      final endIso = state.endDate.toIso8601String();

      final paymentsRevenueResponse = await supabase
          .from('payments')
          .select('amount, created_at, orders(sales_channel)')
          .eq('restaurant_id', restaurantId)
          .eq('is_revenue', true)
          .gte('created_at', startIso)
          .lte('created_at', endIso);

      final externalSalesResponse = await supabase
          .from('external_sales')
          .select('net_amount, completed_at')
          .eq('restaurant_id', restaurantId)
          .eq('is_revenue', true)
          .eq('order_status', 'completed')
          .gte('completed_at', startIso)
          .lte('completed_at', endIso);

      final servicePaymentsResponse = await supabase
          .from('payments')
          .select('amount')
          .eq('restaurant_id', restaurantId)
          .eq('is_revenue', false)
          .gte('created_at', startIso)
          .lte('created_at', endIso);

      final ordersResponse = await supabase
          .from('orders')
          .select('id, status')
          .eq('restaurant_id', restaurantId)
          .gte('created_at', startIso)
          .lte('created_at', endIso);

      double dineInRevenue = 0;
      final dailyMap = <String, _DailyAccumulator>{};

      for (final row in paymentsRevenueResponse) {
        final payment = Map<String, dynamic>.from(row);
        final amount = _toDouble(payment['amount']);
        final createdAt = _parseDateTime(payment['created_at']) ?? state.startDate;
        final dateKey = DateFormat('yyyy-MM-dd').format(createdAt);
        final accumulator = dailyMap.putIfAbsent(dateKey, () => _DailyAccumulator(date: DateTime(createdAt.year, createdAt.month, createdAt.day)));

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
        final completedAt = _parseDateTime(external['completed_at']) ?? state.startDate;
        final dateKey = DateFormat('yyyy-MM-dd').format(completedAt);
        final accumulator = dailyMap.putIfAbsent(dateKey, () => _DailyAccumulator(date: DateTime(completedAt.year, completedAt.month, completedAt.day)));
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
          .where((order) => order['status']?.toString().toLowerCase() == 'completed')
          .length;

      final breakdown = dailyMap.values
          .map(
            (day) => DailyRevenue(
              date: day.date,
              dineIn: day.dineIn,
              delivery: day.delivery,
              total: day.dineIn + day.delivery,
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
}

final reportProvider = StateNotifierProvider<ReportNotifier, ReportState>(
  (ref) => ReportNotifier(),
);
