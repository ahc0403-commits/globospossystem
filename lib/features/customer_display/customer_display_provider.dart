import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/utils/live_sync_scope.dart';
import '../../main.dart';

class CustomerDisplayItem {
  const CustomerDisplayItem({
    required this.name,
    required this.quantity,
    required this.amount,
  });

  final String name;
  final int quantity;
  final double amount;

  factory CustomerDisplayItem.fromJson(Map<String, dynamic> json) {
    return CustomerDisplayItem(
      name: json['name']?.toString() ?? '-',
      quantity: _toInt(json['quantity']),
      amount: _toDouble(json['amount']),
    );
  }
}

class CustomerDisplaySnapshot {
  const CustomerDisplaySnapshot({
    required this.orderId,
    required this.localeCode,
    required this.tableNumber,
    required this.items,
    required this.subtotal,
    required this.serviceCharge,
    required this.discount,
    required this.total,
  });

  final String orderId;
  final String localeCode;
  final String tableNumber;
  final List<CustomerDisplayItem> items;
  final double subtotal;
  final double serviceCharge;
  final double discount;
  final double total;

  factory CustomerDisplaySnapshot.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    return CustomerDisplaySnapshot(
      orderId: json['order_id']?.toString() ?? '',
      localeCode: switch (json['locale_code']?.toString()) {
        'vi' => 'vi',
        'en' => 'en',
        _ => 'ko',
      },
      tableNumber: json['table_number']?.toString() ?? '-',
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) => CustomerDisplayItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
      subtotal: _toDouble(json['subtotal']),
      serviceCharge: _toDouble(json['service_charge']),
      discount: _toDouble(json['discount']),
      total: _toDouble(json['total']),
    );
  }
}

class CustomerDisplayState {
  const CustomerDisplayState({
    this.isLoading = false,
    this.snapshot,
    this.error,
  });

  final bool isLoading;
  final CustomerDisplaySnapshot? snapshot;
  final String? error;
}

class CustomerDisplayNotifier extends StateNotifier<CustomerDisplayState> {
  CustomerDisplayNotifier() : super(const CustomerDisplayState());

  static const _fallbackRefreshInterval = Duration(seconds: 15);

  RealtimeChannel? _channel;
  Timer? _pollTimer;
  String? _storeId;

  Future<void> start(String storeId) async {
    if (_storeId == storeId && _channel != null) return;
    _storeId = storeId;
    state = const CustomerDisplayState(isLoading: true);
    await _channel?.unsubscribe();
    _pollTimer?.cancel();

    await _load(storeId);
    _channel = supabase
        .channel(LiveSyncScope.storeChannel('customer_display', storeId))
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'customer_payment_displays',
          filter: LiveSyncScope.storeFilter(storeId),
          callback: (_) => unawaited(_load(storeId)),
        )
        .subscribe();

    _pollTimer = Timer.periodic(_fallbackRefreshInterval, (_) {
      if (mounted && _storeId == storeId) {
        unawaited(_load(storeId));
      }
    });
  }

  Future<void> retry() async {
    final storeId = _storeId;
    if (storeId == null) return;
    state = CustomerDisplayState(isLoading: true, snapshot: state.snapshot);
    await _load(storeId);
  }

  Future<void> _load(String storeId) async {
    try {
      final row = await supabase
          .from('customer_payment_displays')
          .select('status, payload')
          .eq('store_id', storeId)
          .maybeSingle();
      if (!mounted || _storeId != storeId) return;

      final rawPayload = row?['payload'];
      final isShowing = row?['status']?.toString() == 'showing';
      final snapshot = isShowing && rawPayload is Map
          ? CustomerDisplaySnapshot.fromJson(
              Map<String, dynamic>.from(rawPayload),
            )
          : null;
      state = CustomerDisplayState(snapshot: snapshot);
    } catch (error) {
      if (!mounted || _storeId != storeId) return;
      state = CustomerDisplayState(
        snapshot: state.snapshot,
        error: error.toString(),
      );
    }
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _channel?.unsubscribe();
    super.dispose();
  }
}

final customerDisplayProvider =
    StateNotifierProvider.autoDispose<
      CustomerDisplayNotifier,
      CustomerDisplayState
    >((ref) => CustomerDisplayNotifier());

double _toDouble(dynamic value) => switch (value) {
  num number => number.toDouble(),
  String text => double.tryParse(text) ?? 0,
  _ => 0,
};

int _toInt(dynamic value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};
