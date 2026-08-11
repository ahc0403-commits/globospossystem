import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../core/services/digital_receipt_service.dart';
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
    required this.vat,
    required this.total,
    this.phase = 'payment',
    this.displayRevision,
    this.receiptId,
    this.receiptUrl,
  });

  final String orderId;
  final String localeCode;
  final String tableNumber;
  final List<CustomerDisplayItem> items;
  final double subtotal;
  final double serviceCharge;
  final double discount;
  final double vat;
  final double total;
  final String phase;
  final String? displayRevision;
  final String? receiptId;
  final String? receiptUrl;

  bool get isReceipt => phase == 'receipt';

  CustomerDisplaySnapshot copyWith({String? receiptUrl}) =>
      CustomerDisplaySnapshot(
        orderId: orderId,
        localeCode: localeCode,
        tableNumber: tableNumber,
        items: items,
        subtotal: subtotal,
        serviceCharge: serviceCharge,
        discount: discount,
        vat: vat,
        total: total,
        phase: phase,
        displayRevision: displayRevision,
        receiptId: receiptId,
        receiptUrl: receiptUrl ?? this.receiptUrl,
      );

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
      vat: _toDouble(json['vat']),
      total: _toDouble(json['total']),
      phase: json['phase']?.toString() == 'receipt' ? 'receipt' : 'payment',
      displayRevision: json['display_revision']?.toString(),
      receiptId: json['receipt_id']?.toString(),
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

  // A subscribed socket does not guarantee that Postgres change events are
  // actually reaching this device. Keep the indexed single-row fallback fast
  // even while Realtime reports a healthy connection.
  static const _connectedHealthRefreshInterval = Duration(seconds: 1);
  static const _disconnectedRefreshInterval = Duration(seconds: 1);
  static const receiptDisplayDuration = Duration(seconds: 90);

  RealtimeChannel? _channel;
  Timer? _pollTimer;
  Timer? _receiptTimer;
  String? _storeId;
  Duration? _pollInterval;
  bool _realtimeConnected = false;
  int _realtimeRevision = 0;
  String? _resolvedReceiptId;
  String? _resolvedReceiptUrl;
  String? _failedReceiptId;
  DateTime? _receiptRetryAfter;
  String? _resolvingReceiptId;
  String? _visibleReceiptRevision;
  String? _hiddenReceiptRevision;

  Future<void> start(String storeId) async {
    if (_storeId == storeId && _channel != null) return;
    _storeId = storeId;
    state = const CustomerDisplayState(isLoading: true);
    await _channel?.unsubscribe();
    _channel = null;
    _pollTimer?.cancel();
    _receiptTimer?.cancel();
    _pollTimer = null;
    _pollInterval = null;
    _realtimeConnected = false;
    _realtimeRevision = 0;
    _resolvedReceiptId = null;
    _resolvedReceiptUrl = null;
    _failedReceiptId = null;
    _receiptRetryAfter = null;
    _resolvingReceiptId = null;
    _visibleReceiptRevision = null;
    _hiddenReceiptRevision = null;

    _channel = supabase
        .channel(LiveSyncScope.storeChannel('customer_display', storeId))
        .onPostgresChanges(
          event: PostgresChangeEvent.all,
          schema: 'public',
          table: 'customer_payment_displays',
          filter: LiveSyncScope.storeFilter(storeId, column: 'store_id'),
          callback: (payload) => _applyRealtimeChange(storeId, payload),
        )
        .subscribe((status, [error]) {
          if (!mounted || _storeId != storeId) return;
          final connected = status == RealtimeSubscribeStatus.subscribed;
          if (connected == _realtimeConnected) return;
          _realtimeConnected = connected;
          _ensurePolling(storeId);
        });

    _ensurePolling(storeId);
    await _load(storeId);
  }

  Future<void> retry() async {
    final storeId = _storeId;
    if (storeId == null) return;
    state = CustomerDisplayState(isLoading: true, snapshot: state.snapshot);
    await _load(storeId);
  }

  Future<void> _load(String storeId) async {
    final revision = _realtimeRevision;
    try {
      final row = await supabase
          .from('customer_payment_displays')
          .select('store_id, status, payload')
          .eq('store_id', storeId)
          .maybeSingle();
      if (!mounted || _storeId != storeId || revision != _realtimeRevision) {
        return;
      }

      _applyRow(storeId, row);
    } catch (error) {
      if (!mounted || _storeId != storeId) return;
      state = CustomerDisplayState(
        snapshot: state.snapshot,
        error: error.toString(),
      );
    }
  }

  void _applyRealtimeChange(String storeId, PostgresChangePayload payload) {
    if (!mounted || _storeId != storeId) return;
    _realtimeRevision += 1;
    final row = payload.newRecord;
    if (row.isEmpty) {
      unawaited(_load(storeId));
      return;
    }
    _applyRow(storeId, row);
  }

  void _applyRow(String storeId, Map<String, dynamic>? row) {
    if (!mounted || _storeId != storeId) return;
    final rowStoreId = row?['store_id']?.toString();
    if (rowStoreId != null && rowStoreId != storeId) return;

    final rawPayload = row?['payload'];
    final isShowing = row?['status']?.toString() == 'showing';
    var snapshot = isShowing && rawPayload is Map
        ? CustomerDisplaySnapshot.fromJson(
            Map<String, dynamic>.from(rawPayload),
          )
        : null;
    if (snapshot?.isReceipt == true) {
      final revision = snapshot!.displayRevision ?? snapshot.receiptId;
      if (revision != null && revision == _hiddenReceiptRevision) {
        state = const CustomerDisplayState();
        return;
      }
      if (snapshot.receiptId == _resolvedReceiptId) {
        snapshot = snapshot.copyWith(receiptUrl: _resolvedReceiptUrl);
      } else if (snapshot.receiptId == _failedReceiptId &&
          DateTime.now().isBefore(
            _receiptRetryAfter ?? DateTime.fromMillisecondsSinceEpoch(0),
          )) {
        snapshot = snapshot.copyWith(receiptUrl: '');
      } else if (snapshot.receiptId != _resolvingReceiptId) {
        unawaited(_resolveReceiptLink(storeId, snapshot));
      }
      if (revision != null && revision != _visibleReceiptRevision) {
        _visibleReceiptRevision = revision;
        _receiptTimer?.cancel();
        _receiptTimer = Timer(receiptDisplayDuration, () {
          if (!mounted || _storeId != storeId) return;
          _hiddenReceiptRevision = revision;
          state = const CustomerDisplayState();
        });
      }
    } else {
      _receiptTimer?.cancel();
      _visibleReceiptRevision = null;
      _hiddenReceiptRevision = null;
    }
    state = CustomerDisplayState(snapshot: snapshot);
  }

  Future<void> _resolveReceiptLink(
    String storeId,
    CustomerDisplaySnapshot snapshot,
  ) async {
    final receiptId = snapshot.receiptId;
    if (receiptId == null || receiptId.isEmpty) return;
    _resolvingReceiptId = receiptId;
    try {
      final access = await digitalReceiptService.issueLink(receiptId);
      if (!mounted || _storeId != storeId) return;
      final current = state.snapshot;
      if (current?.receiptId != receiptId || current?.isReceipt != true) return;
      _resolvedReceiptId = receiptId;
      _resolvedReceiptUrl = access.publicUrl;
      _failedReceiptId = null;
      _receiptRetryAfter = null;
      state = CustomerDisplayState(
        snapshot: current!.copyWith(receiptUrl: access.publicUrl),
      );
    } catch (error) {
      if (!mounted || _storeId != storeId) return;
      _failedReceiptId = receiptId;
      _receiptRetryAfter = DateTime.now().add(const Duration(seconds: 15));
      state = CustomerDisplayState(
        snapshot: state.snapshot?.copyWith(receiptUrl: ''),
        error: error.toString(),
      );
    } finally {
      if (_resolvingReceiptId == receiptId) _resolvingReceiptId = null;
    }
  }

  void _ensurePolling(String storeId) {
    final interval = _realtimeConnected
        ? _connectedHealthRefreshInterval
        : _disconnectedRefreshInterval;
    if (_pollTimer != null && _pollInterval == interval) return;

    _pollTimer?.cancel();
    _pollInterval = interval;
    _pollTimer = Timer.periodic(interval, (_) {
      if (mounted && _storeId == storeId) {
        unawaited(_load(storeId));
      }
    });
  }

  @visibleForTesting
  static Duration fallbackIntervalForConnection({required bool connected}) {
    return connected
        ? _connectedHealthRefreshInterval
        : _disconnectedRefreshInterval;
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    _receiptTimer?.cancel();
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
