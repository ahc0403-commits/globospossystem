import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A payload-free signal telling a screen to refetch data through its normal,
/// RLS-protected query path.
class PosLiveEvent {
  const PosLiveEvent({
    required this.domain,
    required this.sourceTable,
    required this.eventType,
    this.restaurantId,
    this.isFallback = false,
  });

  const PosLiveEvent.fallback()
    : domain = '*',
      sourceTable = '',
      eventType = 'POLL',
      restaurantId = null,
      isFallback = true;

  final String domain;
  final String sourceTable;
  final String eventType;
  final String? restaurantId;
  final bool isFallback;

  bool affects(Set<String> domains) =>
      isFallback || domain == '*' || domains.contains(domain);

  factory PosLiveEvent.fromRecord(Map<String, dynamic> record) {
    return PosLiveEvent(
      domain: record['domain']?.toString() ?? '*',
      sourceTable: record['source_table']?.toString() ?? '',
      eventType: record['event_type']?.toString() ?? 'UPDATE',
      restaurantId: record['restaurant_id']?.toString(),
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
      if (Supabase.instance.client.auth.currentSession == null) {
        return const Stream<PosLiveEvent>.empty();
      }

      final controller = StreamController<PosLiveEvent>.broadcast();
      Timer? debounceTimer;
      PosLiveEvent? pendingEvent;
      var realtimeConnected = false;

      void emitDebounced(PosLiveEvent event) {
        final pending = pendingEvent;
        pendingEvent =
            pending != null &&
                (pending.domain != event.domain ||
                    pending.restaurantId != event.restaurantId)
            ? PosLiveEvent(
                domain: '*',
                sourceTable: '*',
                eventType: 'UPDATE',
                restaurantId: event.restaurantId,
              )
            : event;
        debounceTimer?.cancel();
        debounceTimer = Timer(const Duration(milliseconds: 350), () {
          final next = pendingEvent;
          pendingEvent = null;
          if (next != null && !controller.isClosed) {
            controller.add(next);
          }
        });
      }

      var channel = Supabase.instance.client
          .channel('public:pos_live_events:$storeId')
          .onPostgresChanges(
            event: PostgresChangeEvent.insert,
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
              emitDebounced(PosLiveEvent.fromRecord(payload.newRecord));
            },
          );
      channel = channel.subscribe((status, [error]) {
        realtimeConnected = status == RealtimeSubscribeStatus.subscribed;
      });

      // Realtime reconnects automatically. The low-frequency safety tick
      // covers periods where the SDK reports a disconnected channel.
      final fallbackTimer = Timer.periodic(const Duration(seconds: 30), (_) {
        if (!realtimeConnected && !controller.isClosed) {
          controller.add(const PosLiveEvent.fallback());
        }
      });

      ref.onDispose(() {
        debounceTimer?.cancel();
        fallbackTimer.cancel();
        unawaited(channel.unsubscribe());
        unawaited(controller.close());
      });

      return controller.stream;
    });
