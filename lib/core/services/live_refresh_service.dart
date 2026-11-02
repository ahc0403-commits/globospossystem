import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../utils/polling_utils.dart';

typedef _LiveChange = ({String domain, String sourceTable, String eventType});

/// A payload-free signal telling a screen to refetch data through its normal,
/// RLS-protected query path.
class PosLiveEvent {
  const PosLiveEvent({
    required this.domain,
    required this.sourceTable,
    required this.eventType,
    this.restaurantId,
    this.isFallback = false,
    this.affectedDomains,
    this.affectedRestaurantIds,
    this.affectedMenuItemIds,
  }) : _changes = null;

  const PosLiveEvent._merged({
    required this.domain,
    required this.sourceTable,
    required this.eventType,
    required this.restaurantId,
    required this.isFallback,
    required this.affectedDomains,
    required this.affectedRestaurantIds,
    required this.affectedMenuItemIds,
    required Set<_LiveChange> changes,
  }) : _changes = changes;

  const PosLiveEvent.fallback()
    : domain = '*',
      sourceTable = '',
      eventType = 'POLL',
      restaurantId = null,
      isFallback = true,
      affectedDomains = null,
      affectedRestaurantIds = null,
      affectedMenuItemIds = null,
      _changes = null;

  final String domain;
  final String sourceTable;
  final String eventType;
  final String? restaurantId;
  final bool isFallback;
  final Set<String>? affectedDomains;
  final Set<String>? affectedRestaurantIds;

  /// IDs only, capped by the producer and merger; no prices or business rows.
  /// Null means a compatible full/recovery read is required.
  final Set<String>? affectedMenuItemIds;

  /// Null denotes a global/recovery signal; multiple stores retain their scope.
  Set<String>? get restaurantIds => isFallback
      ? null
      : affectedRestaurantIds ??
            (restaurantId == null ? null : {restaurantId!});
  final Set<_LiveChange>? _changes;

  Set<_LiveChange> get _changeKinds =>
      _changes ??
      {(domain: domain, sourceTable: sourceTable, eventType: eventType)};

  /// Match an original change, not a combination synthesized from different
  /// records. Deduplicated kinds contain no row payloads or identifiers.
  bool includesChange({
    required String domain,
    required String sourceTable,
    required String eventType,
  }) => _changeKinds.contains((
    domain: domain,
    sourceTable: sourceTable,
    eventType: eventType,
  ));

  bool affects(Set<String> domains) =>
      isFallback ||
      (affectedDomains ?? {domain}).any(
        (value) => value == '*' || domains.contains(value),
      );

  bool onlySourceTables(Set<String> tables) =>
      !isFallback &&
      _changeKinds.every((change) => tables.contains(change.sourceTable));

  /// Preserve original table kinds in merged signals; job/order events must
  /// not reload printer configuration. Recovery still reconciles all data.
  bool affectsSourceTables(Set<String> tables) =>
      isFallback ||
      _changeKinds.any((change) => tables.contains(change.sourceTable));

  bool get onlyMenuQuantityChanges =>
      !isFallback &&
      affects({'menu'}) &&
      _changeKinds
          .where((change) => change.domain == 'menu' || change.domain == '*')
          .every((change) => change.sourceTable == 'menu_discount_quantities');

  Set<String>? _mergeMenuIds(PosLiveEvent other) {
    if ((affects({'menu'}) && affectedMenuItemIds == null) ||
        (other.affects({'menu'}) && other.affectedMenuItemIds == null)) {
      return null;
    }
    final ids = {...?affectedMenuItemIds, ...?other.affectedMenuItemIds};
    return ids.length <= 100 ? Set.unmodifiable(ids) : null;
  }

  PosLiveEvent merge(PosLiveEvent other) => PosLiveEvent._merged(
    domain: domain == other.domain ? domain : '*',
    sourceTable: sourceTable == other.sourceTable ? sourceTable : '*',
    eventType: eventType == other.eventType ? eventType : 'UPDATE',
    restaurantId: restaurantId == other.restaurantId ? restaurantId : null,
    isFallback: isFallback || other.isFallback,
    affectedDomains: Set.unmodifiable({
      ...?affectedDomains,
      if (affectedDomains == null) domain,
      ...?other.affectedDomains,
      if (other.affectedDomains == null) other.domain,
    }),
    affectedMenuItemIds: _mergeMenuIds(other),
    affectedRestaurantIds:
        restaurantIds == null ||
            other.restaurantIds == null ||
            {...restaurantIds!, ...other.restaurantIds!}.length > 500
        ? null
        : Set.unmodifiable({...restaurantIds!, ...other.restaurantIds!}),
    changes: Set.unmodifiable({..._changeKinds, ...other._changeKinds}),
  );

  factory PosLiveEvent.fromRecord(Map<String, dynamic> record) {
    final rawIds = record['affected_ids'];
    final ids =
        rawIds is List &&
            rawIds.length <= 100 &&
            rawIds.every((id) => id is String && id.isNotEmpty)
        ? Set<String>.unmodifiable(rawIds.cast<String>())
        : null;
    return PosLiveEvent(
      domain: record['domain']?.toString() ?? '*',
      sourceTable: record['source_table']?.toString() ?? '',
      eventType: record['event_type']?.toString() ?? 'UPDATE',
      restaurantId: record['restaurant_id']?.toString(),
      affectedMenuItemIds: ids,
    );
  }
}

/// Store id `*` is reserved for cross-store dashboards such as Super Admin
/// and Photo Objet. All other callers receive a server-filtered store stream.
final posLiveEventsProvider = StreamProvider.autoDispose
    .family<PosLiveEvent, String>((ref, storeId) {
      // Staff feeds are authenticated by RLS. Avoid opening a socket before
      // the auth session exists (and keep unauthenticated widget surfaces
      // side-effect free); the provider is recreated when the signed-in
      // profile mounts its store-scoped listener.
      SupabaseClient client;
      try {
        client = Supabase.instance.client;
      } on AssertionError {
        return const Stream<PosLiveEvent>.empty();
      }
      if (client.auth.currentSession == null) {
        return const Stream<PosLiveEvent>.empty();
      }

      final controller = StreamController<PosLiveEvent>.broadcast();
      Timer? debounceTimer;
      PosLiveEvent? pendingEvent;
      var realtimeConnected = false;

      void emitDebounced(PosLiveEvent event) {
        pendingEvent = pendingEvent?.merge(event) ?? event;
        // Fixed window: continuous traffic must not postpone refresh forever.
        debounceTimer ??= Timer(const Duration(milliseconds: 350), () {
          debounceTimer = null;
          final next = pendingEvent;
          pendingEvent = null;
          if (next != null && !controller.isClosed) {
            controller.add(next);
          }
        });
      }

      var channel = client
          .channel('public:pos_live_events:$storeId')
          .onPostgresChanges(
            event: PostgresChangeEvent.all,
            schema: 'public',
            table: 'pos_live_events',
            filter: storeId == '*'
                ? null
                : PostgresChangeFilter(
                    type: PostgresChangeFilterType.eq,
                    column: 'restaurant_id',
                    value: storeId,
                  ),
            callback: (payload) {
              // Retention deletes are not source changes. UPDATE is used only
              // to merge IDs into the transaction's existing quota signal.
              if (payload.newRecord.isEmpty) return;
              emitDebounced(PosLiveEvent.fromRecord(payload.newRecord));
            },
          );
      channel = channel.subscribe((status, [error]) {
        final connected = status == RealtimeSubscribeStatus.subscribed;
        if (connected && !realtimeConnected) {
          // Reconcile changes missed before the first join or during reconnect.
          emitDebounced(const PosLiveEvent.fallback());
        }
        realtimeConnected = connected;
      });

      // Realtime reconnects automatically. The low-frequency safety tick
      // covers periods where the SDK reports a disconnected channel.
      Timer? fallbackTimer;
      void scheduleFallback() {
        fallbackTimer?.cancel();
        fallbackTimer = Timer(
          jitteredPollDelay(const Duration(seconds: 30)),
          () {
            fallbackTimer = null;
            if (!realtimeConnected && !controller.isClosed) {
              controller.add(const PosLiveEvent.fallback());
            }
            if (!controller.isClosed) scheduleFallback();
          },
        );
      }

      scheduleFallback();

      ref.onDispose(() {
        debounceTimer?.cancel();
        fallbackTimer?.cancel();
        unawaited(channel.unsubscribe());
        unawaited(controller.close());
      });

      return controller.stream;
    });
