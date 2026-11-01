import 'dart:convert';
import '../../core/services/emergency_web_bridge.dart';

/// The existing durable web/native store. An injected adapter lets command
/// tests fail persistence independently of the network, without weakening it.
class KdsOutboxStore {
  final _routes = <String, bool>{};

  void _validateProgress(String id, Map payload) {
    if (payload['_outbox_progress_journal'] != 1 ||
        payload['event_id'] != id ||
        !const {'prepared', 'queued'}.contains(payload['_outbox_phase']) ||
        [
          'item_id',
          'queue_id',
          'stage',
          '_outbox_store_id',
          '_outbox_actor_id',
          '_outbox_session_id',
        ].any(
          (key) => payload[key] is! String || (payload[key] as String).isEmpty,
        ) ||
        !const {-1, 1}.contains(payload['delta'])) {
      throw const FormatException('KDS_OUTBOX_PROGRESS_SCHEMA_INVALID');
    }
  }

  Future<void> put(String id, String payload) async {
    final decoded = jsonDecode(payload) as Map;
    final progress = decoded['_outbox_progress_journal'] == 1;
    if (progress) _validateProgress(id, decoded);
    _routes[id] = progress;
    if (progress) {
      await EmergencyWebBridge.putProgressJournal(id, payload);
    } else {
      await EmergencyWebBridge.putOutbox(id, payload);
    }
  }

  Future<List<EmergencyOutboxRecord>> read() async {
    final stores = await Future.wait([
      EmergencyWebBridge.readOutbox(),
      EmergencyWebBridge.readProgressJournal(),
    ]);
    final legacy = stores[0], progress = stores[1];
    _routes.clear();
    final ids = <String>{};
    for (final (list, isProgress) in [(legacy, false), (progress, true)]) {
      for (final record in list) {
        if (isProgress) {
          _validateProgress(record.id, jsonDecode(record.payload) as Map);
        }
        if (!ids.add(record.id)) {
          throw const FormatException('KDS_OUTBOX_DUPLICATE_ID');
        }
        _routes[record.id] = isProgress;
      }
    }
    final records = [...legacy, ...progress].indexed.toList(growable: false);
    records.sort((a, b) {
      final time = a.$2.createdAtEpochMs.compareTo(b.$2.createdAtEpochMs);
      return time == 0 ? a.$1.compareTo(b.$1) : time;
    });
    return records.map((row) => row.$2).toList(growable: false);
  }

  Future<void> delete(String id) async {
    if (!_routes.containsKey(id)) await read();
    if (!_routes.containsKey(id)) return;
    if (_routes[id]!) {
      await EmergencyWebBridge.deleteProgressJournal(id);
    } else {
      await EmergencyWebBridge.deleteOutbox(id);
    }
    _routes.remove(id);
  }
}

/// New records retain their original actor and station assignment. Older
/// store-only records keep the existing server-authorized compatibility path.
bool kdsOutboxScopeMatches(
  Map<String, dynamic> payload, {
  required String? storeId,
  required String? actorId,
  required String? sessionId,
  required String? stationType,
  required String? floorLabel,
}) {
  if (storeId == null || storeId.isEmpty) return false;
  for (final (field, actual) in [
    ('_outbox_store_id', storeId),
    ('_outbox_actor_id', actorId),
    ('_outbox_session_id', sessionId),
    ('_outbox_station_type', stationType),
    ('_outbox_floor_label', floorLabel),
  ]) {
    final expected = payload[field]?.toString();
    if (expected != null && expected.isNotEmpty && expected != actual) {
      return false;
    }
  }
  return true;
}

/// A result lookup must match the original intent, not just find a UUID.
/// Existing RPCs serialize by item and retain their unique event/request IDs.
/// Receipt reads enforce active actor/store access and use the unique indexes.
bool kdsProgressReceiptMatches(Map<String, dynamic> payload, Map row) {
  if (row['event_id'] != payload['event_id'] ||
      row['delta'] != payload['delta'] ||
      row['session_id'] != payload['_outbox_session_id']) {
    return false;
  }
  final stage = payload['stage'];
  final details = row['details'];
  if (details is Map &&
      details['source_id'] != null &&
      details['source_id'] != payload['item_id']) {
    return false;
  }
  if (details is Map && details['workflow_action'] != null) {
    if (details['workflow_action'] != stage) return false;
  } else if (row['stage'] != stage &&
      !(payload['workflow_v2'] == true &&
          ((stage == 'kitchen_started' && row['stage'] == 'kitchen_done') ||
              (stage == 'tray_ready' && row['stage'] == 'tray_dispatched')))) {
    return false;
  }
  if (payload['floor_direct'] == true) {
    return row['floor_direct_item_id'] == payload['item_id'];
  }
  if (payload['combo_component'] == true) {
    return row['combo_component_item_id'] == payload['item_id'];
  }
  return row['order_item_id'] == payload['_outbox_order_item_id'];
}
