import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum KdsSyncMode {
  legacy,
  shadow,
  active;

  static KdsSyncMode fromValue(Object? value) => switch (value?.toString()) {
    'shadow' => KdsSyncMode.shadow,
    'active' => KdsSyncMode.active,
    _ => KdsSyncMode.legacy,
  };
}

class KdsSyncConfig {
  const KdsSyncConfig({
    required this.mode,
    required this.revision,
    required this.assigned,
    this.restaurantId,
    this.sessionId,
    this.stationType,
    this.floorLabel,
  });

  const KdsSyncConfig.legacy()
    : mode = KdsSyncMode.legacy,
      revision = 0,
      assigned = false,
      restaurantId = null,
      sessionId = null,
      stationType = null,
      floorLabel = null;

  final KdsSyncMode mode;
  final int revision;
  final bool assigned;
  final String? restaurantId;
  final String? sessionId;
  final String? stationType;
  final String? floorLabel;

  bool hasSameSubscriptionAs(KdsSyncConfig other) =>
      mode == other.mode &&
      assigned == other.assigned &&
      restaurantId == other.restaurantId &&
      sessionId == other.sessionId &&
      stationType == other.stationType &&
      floorLabel == other.floorLabel;

  factory KdsSyncConfig.fromJson(Map<String, dynamic> json) => KdsSyncConfig(
    mode: KdsSyncMode.fromValue(json['mode']),
    revision: _asInt(json['revision']),
    assigned: json['assigned'] == true,
    restaurantId: json['restaurant_id']?.toString(),
    sessionId: json['session_id']?.toString(),
    stationType: json['station_type']?.toString(),
    floorLabel: json['floor_label']?.toString(),
  );
}

class KdsBootstrap {
  const KdsBootstrap({
    required this.config,
    required this.snapshot,
    required this.completedOrders,
    required this.timings,
    required this.fulfillmentMode,
  });

  final KdsSyncConfig config;
  final Map<String, dynamic> snapshot;
  final List<dynamic> completedOrders;
  final List<dynamic> timings;
  final String fulfillmentMode;

  factory KdsBootstrap.fromJson(Map<String, dynamic> json) {
    final rawSync = json['sync'];
    final rawSnapshot = json['snapshot'];
    return KdsBootstrap(
      config: KdsSyncConfig.fromJson(
        rawSync is Map
            ? Map<String, dynamic>.from(rawSync)
            : const <String, dynamic>{},
      ),
      snapshot: rawSnapshot is Map
          ? Map<String, dynamic>.from(rawSnapshot)
          : <String, dynamic>{},
      completedOrders: json['completed_orders'] is List
          ? List<dynamic>.from(json['completed_orders'] as List)
          : const [],
      timings: json['timings'] is List
          ? List<dynamic>.from(json['timings'] as List)
          : const [],
      fulfillmentMode: json['fulfillment_mode']?.toString() ?? 'paperless',
    );
  }
}

class KdsChangeEnvelope {
  const KdsChangeEnvelope({
    required this.schemaVersion,
    required this.restaurantId,
    required this.revision,
    required this.eventId,
    required this.eventType,
    required this.targetStations,
    required this.payload,
    required this.occurredAt,
    this.sessionId,
    this.targetFloorLabel,
    this.queueId,
    this.orderId,
    this.orderItemId,
  });

  final int schemaVersion;
  final String restaurantId;
  final String? sessionId;
  final int revision;
  final String eventId;
  final String eventType;
  final List<String> targetStations;
  final String? targetFloorLabel;
  final String? queueId;
  final String? orderId;
  final String? orderItemId;
  final Map<String, dynamic> payload;
  final DateTime occurredAt;

  String get kind => payload['kind']?.toString() ?? 'ticket_invalidated';

  factory KdsChangeEnvelope.fromJson(Map<String, dynamic> json) {
    final rawPayload = json['payload'];
    final rawTargets = json['target_stations'];
    final revision = _asInt(json['revision']);
    final restaurantId = json['restaurant_id']?.toString() ?? '';
    final eventId = json['event_id']?.toString() ?? '';
    if (_asInt(json['schema_version']) != 1 ||
        revision <= 0 ||
        restaurantId.isEmpty ||
        eventId.isEmpty) {
      throw const FormatException('KDS_CHANGE_ENVELOPE_INVALID');
    }
    return KdsChangeEnvelope(
      schemaVersion: 1,
      restaurantId: restaurantId,
      sessionId: json['session_id']?.toString(),
      revision: revision,
      eventId: eventId,
      eventType: json['event_type']?.toString() ?? 'ticket_changed',
      targetStations: rawTargets is List
          ? rawTargets.map((value) => value.toString()).toList(growable: false)
          : const [],
      targetFloorLabel: json['target_floor_label']?.toString(),
      queueId: json['queue_id']?.toString(),
      orderId: json['order_id']?.toString(),
      orderItemId: json['order_item_id']?.toString(),
      payload: rawPayload is Map
          ? Map<String, dynamic>.from(rawPayload)
          : const <String, dynamic>{},
      occurredAt:
          DateTime.tryParse(json['occurred_at']?.toString() ?? '')?.toUtc() ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
    );
  }
}

class KdsDeltaBatch {
  const KdsDeltaBatch({
    required this.bootstrapRequired,
    required this.scannedThroughRevision,
    required this.currentRevision,
    required this.hasMore,
    required this.changes,
  });

  final bool bootstrapRequired;
  final int scannedThroughRevision;
  final int currentRevision;
  final bool hasMore;
  final List<KdsChangeEnvelope> changes;

  factory KdsDeltaBatch.fromJson(Map<String, dynamic> json) {
    final rawChanges = json['changes'];
    return KdsDeltaBatch(
      bootstrapRequired: json['bootstrap_required'] == true,
      scannedThroughRevision: _asInt(json['scanned_through_revision']),
      currentRevision: _asInt(json['current_revision']),
      hasMore: json['has_more'] == true,
      changes: rawChanges is List
          ? rawChanges
                .whereType<Map>()
                .map(
                  (change) => KdsChangeEnvelope.fromJson(
                    Map<String, dynamic>.from(change),
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }
}

class KdsTicketResult {
  const KdsTicketResult({required this.revision, this.ticket});

  final int revision;
  final Map<String, dynamic>? ticket;

  factory KdsTicketResult.fromJson(Map<String, dynamic> json) {
    final rawTicket = json['ticket'];
    return KdsTicketResult(
      revision: _asInt(json['revision']),
      ticket: rawTicket is Map ? Map<String, dynamic>.from(rawTicket) : null,
    );
  }
}

abstract class KdsSyncGateway {
  Future<KdsSyncConfig> loadConfig();

  Future<KdsBootstrap> loadBootstrap();

  Future<KdsDeltaBatch> loadChanges(int afterRevision, {int limit = 100});

  Future<int> loadHighWatermark();

  Future<KdsTicketResult> loadTicket(String queueId);
}

class SupabaseKdsSyncGateway implements KdsSyncGateway {
  const SupabaseKdsSyncGateway(this.client);

  final SupabaseClient client;

  @override
  Future<KdsSyncConfig> loadConfig() async {
    final raw = await client.rpc('get_kds_sync_config');
    return KdsSyncConfig.fromJson(_asMap(raw));
  }

  @override
  Future<KdsBootstrap> loadBootstrap() async {
    final raw = await client.rpc('get_kds_bootstrap_v2');
    return KdsBootstrap.fromJson(_asMap(raw));
  }

  @override
  Future<KdsDeltaBatch> loadChanges(
    int afterRevision, {
    int limit = 100,
  }) async {
    final raw = await client.rpc(
      'get_kds_changes_v2',
      params: {'p_after_revision': afterRevision, 'p_limit': limit},
    );
    return KdsDeltaBatch.fromJson(_asMap(raw));
  }

  @override
  Future<int> loadHighWatermark() async =>
      _asInt(await client.rpc('get_kds_high_watermark_v2'));

  @override
  Future<KdsTicketResult> loadTicket(String queueId) async {
    final raw = await client.rpc(
      'get_kds_ticket_v2',
      params: {'p_queue_id': queueId},
    );
    return KdsTicketResult.fromJson(_asMap(raw));
  }
}

abstract class KdsRevisionStore {
  Future<int?> read(String key);

  Future<void> write(String key, int revision);
}

class SharedPreferencesKdsRevisionStore implements KdsRevisionStore {
  const SharedPreferencesKdsRevisionStore();

  @override
  Future<int?> read(String key) async {
    final preferences = await SharedPreferences.getInstance();
    return preferences.getInt(key);
  }

  @override
  Future<void> write(String key, int revision) async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setInt(key, revision);
  }
}

typedef KdsChangeHandler = Future<void> Function(KdsChangeEnvelope change);
typedef KdsAsyncCallback = Future<void> Function();
typedef KdsSyncErrorHandler = void Function(Object error, StackTrace stack);

class KdsRealtimeSync {
  KdsRealtimeSync({
    required this.client,
    required this.gateway,
    required this.config,
    required this.onChange,
    required this.onBootstrapRequired,
    required this.onConnected,
    required this.onError,
    this.revisionStore = const SharedPreferencesKdsRevisionStore(),
    this.watchdogInterval = const Duration(seconds: 30),
  });

  final SupabaseClient client;
  final KdsSyncGateway gateway;
  final KdsSyncConfig config;
  final KdsChangeHandler onChange;
  final KdsAsyncCallback onBootstrapRequired;
  final KdsAsyncCallback onConnected;
  final KdsSyncErrorHandler onError;
  final KdsRevisionStore revisionStore;
  final Duration watchdogInterval;

  final List<RealtimeChannel> _channels = [];
  Timer? _watchdog;
  bool _disposed = false;
  bool _catchingUp = false;
  bool _catchUpRequested = false;
  bool _connectedCallbackSent = false;
  int _subscribedChannels = 0;
  late int _cursor;

  int get cursor => _cursor;

  @visibleForTesting
  void seedCursorForTesting(int revision) => _cursor = revision;

  String get _cursorKey => <String>[
    'kds-v2',
    config.restaurantId ?? '',
    config.sessionId ?? 'none',
    config.stationType ?? 'none',
    config.floorLabel ?? 'none',
  ].join(':');

  Future<void> start() async {
    if (_disposed || config.mode == KdsSyncMode.legacy) return;
    final stored = await revisionStore.read(_cursorKey);
    if (_disposed) return;
    // The bootstrap already represents every change through config.revision.
    // Never replay older events into alarm-producing state on app restart.
    _cursor = config.revision > (stored ?? 0)
        ? config.revision
        : (stored ?? config.revision);
    await revisionStore.write(_cursorKey, _cursor);
    if (_disposed) return;

    final storeId = config.restaurantId;
    final station = config.stationType;
    if (storeId == null || station == null) return;
    final topics = <String>{'kds:$storeId:control'};
    topics.add(
      station == 'floor'
          ? 'kds:$storeId:floor:${config.floorLabel ?? ''}'
          : 'kds:$storeId:$station',
    );
    for (final topic in topics) {
      final channel = client
          .channel(topic, opts: const RealtimeChannelConfig(private: true))
          .onBroadcast(
            event: 'kds_change',
            callback: (_) => unawaited(catchUp()),
          )
          .subscribe((status, [error]) {
            if (_disposed) return;
            if (status == RealtimeSubscribeStatus.subscribed) {
              _subscribedChannels += 1;
              unawaited(catchUp());
              if (!_connectedCallbackSent &&
                  _subscribedChannels >= topics.length) {
                _connectedCallbackSent = true;
                unawaited(onConnected());
              }
            } else if (status == RealtimeSubscribeStatus.channelError &&
                error != null) {
              onError(error, StackTrace.current);
            }
          });
      _channels.add(channel);
    }
    _watchdog = Timer.periodic(
      watchdogInterval,
      (_) => unawaited(_watchdogTick()),
    );
  }

  Future<void> _watchdogTick() async {
    if (_disposed) return;
    try {
      final latest = await gateway.loadConfig();
      if (!config.hasSameSubscriptionAs(latest)) {
        await onBootstrapRequired();
        return;
      }
      if (latest.revision > _cursor) await catchUp();
    } catch (error, stack) {
      onError(error, stack);
    }
  }

  Future<void> catchUp() async {
    if (_disposed) return;
    _catchUpRequested = true;
    if (_catchingUp) return;
    _catchingUp = true;
    try {
      while (_catchUpRequested && !_disposed) {
        _catchUpRequested = false;
        var pages = 0;
        var hasMore = true;
        while (hasMore && !_disposed) {
          if (pages >= 50) {
            throw StateError('KDS_DELTA_PAGE_LIMIT');
          }
          final batch = await gateway.loadChanges(_cursor);
          if (batch.bootstrapRequired) {
            await onBootstrapRequired();
            return;
          }
          for (final change in batch.changes) {
            if (change.revision <= _cursor) continue;
            await onChange(change);
          }
          if (batch.scannedThroughRevision < _cursor) {
            throw StateError('KDS_DELTA_CURSOR_REGRESSION');
          }
          _cursor = batch.scannedThroughRevision;
          await revisionStore.write(_cursorKey, _cursor);
          hasMore = batch.hasMore && _cursor < batch.currentRevision;
          pages += 1;
        }
      }
    } catch (error, stack) {
      onError(error, stack);
    } finally {
      _catchingUp = false;
      if (_catchUpRequested && !_disposed) unawaited(catchUp());
    }
  }

  Future<KdsTicketResult> loadTicket(String queueId) =>
      gateway.loadTicket(queueId);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _watchdog?.cancel();
    for (final channel in _channels) {
      await channel.unsubscribe();
    }
    _channels.clear();
  }
}

Map<String, dynamic> _asMap(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

int _asInt(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};
