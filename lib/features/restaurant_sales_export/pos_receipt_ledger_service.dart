import '../../main.dart';

typedef LedgerRpc =
    Future<dynamic> Function(String name, Map<String, dynamic> params);

/// A dialog owns this cache. Its keys include session, day, entity, receipt kind
/// and the exact bounded page; expired requests share one in-flight future.
class PosReceiptLedgerService {
  PosReceiptLedgerService({
    LedgerRpc? rpc,
    String Function()? sessionScope,
    DateTime Function()? clock,
  }) : _rpc = rpc ?? ((name, params) => supabase.rpc(name, params: params)),
       _sessionScope =
           sessionScope ??
           (() => supabase.auth.currentSession?.accessToken ?? ''),
       _clock = clock ?? DateTime.now;
  final LedgerRpc _rpc;
  final String Function() _sessionScope;
  final DateTime Function() _clock;
  Future<void> _readTail = Future.value();
  String? _latestReadKey;
  String get sessionScope => _sessionScope();
  final _cache = <String, ({DateTime at, List<Map<String, dynamic>> rows})>{};
  final _pending = <String, Future<List<Map<String, dynamic>>>>{};

  Future<List<Map<String, dynamic>>> page({
    required String day,
    required String entity,
    required bool red,
    required List<String> orderIds,
    bool refresh = false,
  }) {
    if (orderIds.isEmpty) return Future.value(const []);
    if (orderIds.length > 50 || orderIds.toSet().length != orderIds.length) {
      throw ArgumentError('POS_LEDGER_BATCH_LIMIT');
    }
    final session = _sessionScope();
    final key = '$session|$day|$entity|$red|${orderIds.join(',')}';
    _latestReadKey = key;
    final cached = _cache[key];
    if (!refresh &&
        cached != null &&
        _clock().difference(cached.at) < const Duration(seconds: 60)) {
      return Future.value(cached.rows);
    }
    return _pending.putIfAbsent(key, () async {
      try {
        final result = Map<String, dynamic>.from(
          await _read(key, session, {
                'p_business_date': day,
                'p_tax_entity_id': entity,
                'p_order_ids': orderIds,
                'p_red': red,
              })
              as Map,
        );
        if (_sessionScope() != session) {
          throw StateError('POS_LEDGER_SESSION_CHANGED');
        }
        final rows = (result['rows'] as List)
            .whereType<Map>()
            .map((r) => Map<String, dynamic>.from(r))
            .toList();
        if (rows.length != orderIds.length ||
            rows.any((r) => !orderIds.contains(r['order_id']))) {
          throw const FormatException('POS_LEDGER_SCOPE_CHANGED');
        }
        if (_cache.length >= 20) _cache.remove(_cache.keys.first);
        _cache[key] = (at: _clock(), rows: rows);
        return rows;
      } finally {
        _pending.remove(key);
      }
    });
  }

  Future<dynamic> _read(
    String key,
    String session,
    Map<String, dynamic> params,
  ) {
    final result = _readTail.then((_) {
      if (_latestReadKey != key || _sessionScope() != session) {
        throw StateError('POS_LEDGER_SUPERSEDED');
      }
      return _rpc('pos_receipt_ledger_batch', params);
    });
    _readTail = result.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return result;
  }

  Future<Map<String, dynamic>> saveBuyer({
    required String storeId,
    required String orderId,
    required int version,
    required Map<String, dynamic> patch,
    required bool confirm,
  }) async {
    final session = _sessionScope();
    final saved = Map<String, dynamic>.from(
      await _rpc('pos_save_buyer_information', {
            'p_store_id': storeId,
            'p_order_id': orderId,
            'p_expected_version': version,
            'p_patch': patch,
            'p_confirm': confirm,
          })
          as Map,
    );
    if (_sessionScope() != session) {
      throw StateError('POS_LEDGER_SESSION_CHANGED');
    }
    for (final entry in _cache.entries.where(
      (e) => e.key.startsWith('$session|'),
    )) {
      for (final row in entry.value.rows) {
        if (row['order_id'] == orderId) {
          row['buyer'] = saved;
        } else {
          final related = saved['related_buyer_versions'];
          final version = related is Map ? related[row['order_id']] : null;
          if (version is Map && row['buyer'] is Map) {
            row['buyer'] = {
              ...Map<String, dynamic>.from(row['buyer'] as Map),
              for (final key in [
                'buyer_number_type',
                'buyer_number_value',
                'buyer_tax_code',
                'buyer_legal_name',
                'buyer_full_name',
                'buyer_address',
                'buyer_email',
                'buyer_email_cc',
                'buyer_phone',
                'buyer_unit_code',
                'buyer_id',
                'source_note',
              ])
                key: saved[key],
              'buyer_version': version['version'],
              'status': version['status'],
            };
          }
        }
      }
    }
    return saved;
  }
}
