import 'package:supabase_flutter/supabase_flutter.dart';

import '../../main.dart';
import '../utils/time_utils.dart';

class OperationalOrderReview {
  const OperationalOrderReview({
    required this.orderId,
    required this.tableNumber,
    required this.businessDate,
    required this.paidTotal,
  });

  factory OperationalOrderReview.fromJson(Map<String, dynamic> json) =>
      OperationalOrderReview(
        orderId: json['order_id']?.toString() ?? '',
        tableNumber: json['table_number']?.toString() ?? '',
        businessDate: json['business_date']?.toString() ?? '',
        paidTotal: num.tryParse(json['paid_total']?.toString() ?? '') ?? 0,
      );

  final String orderId;
  final String tableNumber;
  final String businessDate;
  final num paidTotal;
}

class OperationalDayState {
  const OperationalDayState({
    required this.enabled,
    required this.window,
    this.cancelledToday = 0,
    this.financialReviews = const [],
    this.supportsClosure = true,
  });

  factory OperationalDayState.fromJson(Map<String, dynamic> json) {
    final fallback = TimeUtils.currentVietnamBusinessDay();
    final start = DateTime.tryParse(json['day_start']?.toString() ?? '');
    final end = DateTime.tryParse(json['day_end']?.toString() ?? '');
    return OperationalDayState(
      enabled: json['enabled'] == true,
      window: start != null && end != null
          ? VietnamBusinessDayWindow(
              dateKey: json['business_date'].toString(),
              startUtc: start.toUtc(),
              endUtc: end.toUtc(),
            )
          : fallback,
      cancelledToday:
          int.tryParse(json['cancelled_today']?.toString() ?? '') ?? 0,
      financialReviews: [
        for (final row in json['financial_reviews'] as List? ?? const [])
          OperationalOrderReview.fromJson(
            Map<String, dynamic>.from(row as Map),
          ),
      ],
    );
  }

  final bool enabled;
  final bool supportsClosure;
  final VietnamBusinessDayWindow window;
  final int cancelledToday;
  final List<OperationalOrderReview> financialReviews;

  bool expiresMutation(DateTime createdAt) =>
      enabled && createdAt.toUtc().isBefore(window.startUtc);
}

class OperationalDayService {
  OperationalDayService({SupabaseClient? client}) : _client = client;
  final SupabaseClient? _client;
  final _pending = <String, Future<OperationalDayState>>{};
  final _cached = <String, (DateTime, OperationalDayState)>{};

  void invalidate(String storeId) =>
      _cached.removeWhere((key, _) => key.endsWith(':$storeId'));

  Future<OperationalDayState> ensureStoreDay(String storeId) async {
    final db = _client ?? supabase;
    final key = '${db.auth.currentUser?.id ?? 'anonymous'}:$storeId';
    final cached = _cached[key];
    final now = DateTime.now().toUtc();
    if (cached != null &&
        now.difference(cached.$1) < const Duration(seconds: 30) &&
        now.isBefore(cached.$2.window.endUtc)) {
      return cached.$2;
    }
    return _pending.putIfAbsent(key, () => _fetch(db, key, storeId));
  }

  Future<OperationalDayState> _fetch(
    SupabaseClient db,
    String key,
    String storeId,
  ) async {
    try {
      final result = await db.rpc(
        'ensure_store_operational_day',
        params: {'p_store_id': storeId},
      );
      final state = OperationalDayState.fromJson(
        Map<String, dynamic>.from(result as Map),
      );
      _cached[key] = (DateTime.now().toUtc(), state);
      return state;
    } on PostgrestException catch (error) {
      // Compatibility during rollout only. Connectivity/authentication errors
      // must never be interpreted as an empty or reset dining room.
      if (error.code != 'PGRST202') rethrow;
      return OperationalDayState(
        enabled: false,
        supportsClosure: false,
        window: TimeUtils.currentVietnamBusinessDay(),
      );
    } finally {
      _pending.remove(key);
    }
  }
}

final operationalDayService = OperationalDayService();
