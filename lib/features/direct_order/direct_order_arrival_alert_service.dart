import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'direct_order_service.dart';

class DirectOrderArrivalCursor {
  const DirectOrderArrivalCursor({
    required this.createdAt,
    required this.requestId,
  });

  final DateTime createdAt;
  final String requestId;

  Map<String, dynamic> toJson() => {
    'created_at': createdAt.toUtc().toIso8601String(),
    'request_id': requestId,
  };

  factory DirectOrderArrivalCursor.fromJson(Map<String, dynamic> json) {
    _expectExactKeys(json, const {'created_at', 'request_id'});
    final createdAt = DateTime.tryParse(json['created_at']?.toString() ?? '');
    final requestId = json['request_id']?.toString() ?? '';
    if (createdAt == null ||
        (requestId != _nilUuid && !_uuidPattern.hasMatch(requestId))) {
      throw const FormatException('Invalid direct-order arrival cursor');
    }
    return DirectOrderArrivalCursor(
      createdAt: createdAt.toUtc(),
      requestId: requestId.toLowerCase(),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DirectOrderArrivalCursor &&
      createdAt == other.createdAt &&
      requestId == other.requestId;

  @override
  int get hashCode => Object.hash(createdAt, requestId);
}

class DirectOrderArrival {
  const DirectOrderArrival({
    required this.requestId,
    required this.createdAt,
    required this.state,
  });

  final String requestId;
  final DateTime createdAt;
  final String state;

  factory DirectOrderArrival.fromJson(Map<String, dynamic> json) {
    _expectExactKeys(json, const {'request_id', 'created_at', 'state'});
    final requestId = json['request_id']?.toString() ?? '';
    final createdAt = DateTime.tryParse(json['created_at']?.toString() ?? '');
    final state = json['state']?.toString() ?? '';
    if (!_uuidPattern.hasMatch(requestId) ||
        createdAt == null ||
        state.isEmpty) {
      throw const FormatException('Invalid direct-order arrival');
    }
    return DirectOrderArrival(
      requestId: requestId.toLowerCase(),
      createdAt: createdAt.toUtc(),
      state: state,
    );
  }
}

class DirectOrderArrivalBatch {
  const DirectOrderArrivalBatch({
    required this.items,
    required this.pendingCount,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<DirectOrderArrival> items;
  final int pendingCount;
  final DirectOrderArrivalCursor nextCursor;
  final bool hasMore;

  factory DirectOrderArrivalBatch.fromJson(Map<String, dynamic> json) {
    _expectExactKeys(json, const {
      'items',
      'pending_count',
      'next_cursor',
      'has_more',
    });
    final rawItems = json['items'];
    final rawPendingCount = json['pending_count'];
    final rawCursor = json['next_cursor'];
    final rawHasMore = json['has_more'];
    if (rawItems is! List ||
        rawItems.any((item) => item is! Map) ||
        rawPendingCount is! num ||
        rawPendingCount.toInt() < 0 ||
        rawPendingCount.toInt() != rawPendingCount ||
        rawCursor is! Map ||
        rawHasMore is! bool) {
      throw const FormatException('Invalid direct-order arrival response');
    }
    return DirectOrderArrivalBatch(
      items: rawItems
          .map(
            (item) => DirectOrderArrival.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(growable: false),
      pendingCount: rawPendingCount.toInt(),
      nextCursor: DirectOrderArrivalCursor.fromJson(
        Map<String, dynamic>.from(rawCursor),
      ),
      hasMore: rawHasMore,
    );
  }
}

class DirectOrderArrivalAlertService {
  DirectOrderArrivalAlertService({
    SupabaseClient? client,
    Future<SharedPreferences> Function()? preferencesLoader,
  }) : _client = client,
       _preferencesLoader = preferencesLoader;

  static const _cursorKeyPrefix = 'direct_order_arrival_cursor_v1_';
  final SupabaseClient? _client;
  final Future<SharedPreferences> Function()? _preferencesLoader;

  SupabaseClient get _supabase => _client ?? Supabase.instance.client;

  Future<SharedPreferences> _preferences() =>
      _preferencesLoader?.call() ?? SharedPreferences.getInstance();

  Future<DirectOrderArrivalCursor?> loadCursor(String storeId) async {
    final preferences = await _preferences();
    final key = '$_cursorKeyPrefix$storeId';
    final encoded = preferences.getString(key);
    if (encoded == null) return null;
    try {
      final decoded = jsonDecode(encoded);
      if (decoded is! Map) throw const FormatException();
      return DirectOrderArrivalCursor.fromJson(
        Map<String, dynamic>.from(decoded),
      );
    } catch (_) {
      await preferences.remove(key);
      return null;
    }
  }

  Future<void> saveCursor(
    String storeId,
    DirectOrderArrivalCursor cursor,
  ) async {
    final preferences = await _preferences();
    final saved = await preferences.setString(
      '$_cursorKeyPrefix$storeId',
      jsonEncode(cursor.toJson()),
    );
    if (!saved) {
      throw const DirectOrderException('DIRECT_ORDER_CURSOR_SAVE_FAILED');
    }
  }

  Future<DirectOrderArrivalBatch> fetchAfter(
    String storeId,
    DirectOrderArrivalCursor? cursor, {
    int limit = 100,
  }) async {
    final raw = await _supabase.rpc(
      'direct_order_arrival_alerts_after',
      params: {
        'p_store_id': storeId,
        'p_after_created_at': cursor?.createdAt.toUtc().toIso8601String(),
        'p_after_id': cursor?.requestId,
        'p_limit': limit,
      },
    );
    if (raw is! Map) {
      throw const FormatException('Invalid direct-order arrival envelope');
    }
    return DirectOrderArrivalBatch.fromJson(Map<String, dynamic>.from(raw));
  }
}

final directOrderArrivalAlertService = DirectOrderArrivalAlertService();

final _uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$',
  caseSensitive: false,
);
const _nilUuid = '00000000-0000-0000-0000-000000000000';

void _expectExactKeys(Map<String, dynamic> json, Set<String> expected) {
  if (json.keys.toSet().length != expected.length ||
      !json.keys.toSet().containsAll(expected)) {
    throw const FormatException('Unexpected direct-order arrival fields');
  }
}
