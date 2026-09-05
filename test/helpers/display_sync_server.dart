import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Local wire fixture: real Supabase HTTP/WebSocket clients, synthetic rows.
/// This verifies client scheduling and reconciliation, not database SQL/RLS.
class DisplaySyncServer {
  late final HttpServer server;
  late final SupabaseClient client;
  final requests = <String, int>{};
  final peers = <WebSocket>[];
  final subscriptions = <String, (WebSocket, List<Map<String, dynamic>>)>{};
  Future<void> Function(String path)? beforeReply;
  bool acknowledgeJoins = true;
  bool _closing = false;
  bool snapshotFailure = false;
  bool displayFailure = false;
  String mode = 'legacy';
  String station = 'tray';
  int revision = 1;
  final displayRows = <String, Map<String, dynamic>>{};
  Map<String, dynamic> snapshot = {
    'assigned': true,
    'active': true,
    'restaurant_id': 'store-1',
    'session_id': 'session-1',
    'station_type': 'tray',
    'orders': [
      {
        'queue_id': 'queue-1',
        'order_id': 'order-1',
        'queue_no': 1,
        'items': [
          {
            'id': 'item-1',
            'order_item_id': 'source-1',
            'ordered_quantity': 2,
            'kitchen_done_quantity': 0,
          },
        ],
      },
    ],
  };

  static Map<String, dynamic> displayRow(
    String order, {
    String store = 'store-1',
  }) => {
    'store_id': store,
    'status': 'showing',
    'payload': {'order_id': order, 'total': 100, 'items': []},
  };

  int count(String path) => requests[path] ?? 0;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    client = SupabaseClient(
      'http://127.0.0.1:${server.port}',
      'fixture-anon-key',
    );
    displayRows['store-1'] = displayRow('order-1');
    server.listen(_handle);
  }

  Future<void> _handle(HttpRequest request) async {
    if (WebSocketTransformer.isUpgradeRequest(request)) {
      final peer = await WebSocketTransformer.upgrade(request);
      peers.add(peer);
      peer.listen((raw) {
        if (_closing || peer.readyState != WebSocket.open) return;
        final frame = Map<String, dynamic>.from(
          jsonDecode(raw as String) as Map,
        );
        final event = frame['event'];
        final topic = frame['topic'] as String;
        if (event == 'phx_join' && !acknowledgeJoins) return;
        if (event == 'phx_join' ||
            event == 'phx_leave' ||
            event == 'heartbeat') {
          final filters = event == 'phx_join'
              ? ((frame['payload']['config']['postgres_changes'] as List?) ??
                        [])
                    .map((value) => Map<String, dynamic>.from(value as Map))
                    .toList()
              : <Map<String, dynamic>>[];
          for (var i = 0; i < filters.length; i++) {
            filters[i]['id'] = i + 1;
          }
          if (event == 'phx_join') subscriptions[topic] = (peer, filters);
          if (event == 'phx_leave') subscriptions.remove(topic);
          peer.add(
            jsonEncode({
              'topic': topic,
              'event': 'phx_reply',
              'ref': frame['ref'],
              'payload': {
                'status': 'ok',
                'response': {'postgres_changes': filters},
              },
            }),
          );
        }
      });
      return;
    }
    final path = request.uri.path.split('/').last;
    requests.update(path, (count) => count + 1, ifAbsent: () => 1);
    // Capture the row before delaying, just like an older response in flight.
    final config = {
      'mode': mode,
      'revision': revision,
      'assigned': true,
      'restaurant_id': 'store-1',
      'session_id': 'session-1',
      'station_type': station,
    };
    final store =
        request.uri.queryParameters['store_id']?.replaceFirst('eq.', '') ??
        'store-1';
    final data = switch (path) {
      'customer_payment_displays' => displayRows[store],
      'get_kds_sync_config' => config,
      'get_kds_bootstrap_v2' => {
        'sync': config,
        'snapshot': snapshot,
        'completed_orders': [],
        'timings': [],
        'fulfillment_mode': 'paperless',
      },
      'get_kds_changes_v2' => {
        'bootstrap_required': false,
        'scanned_through_revision': revision,
        'current_revision': revision,
        'has_more': false,
        'changes': [],
      },
      'get_emergency_station_snapshot' => snapshot,
      'get_emergency_station_today_completed' ||
      'get_emergency_station_timings' => [],
      'get_store_fulfillment_mode' => 'paperless',
      _ => null,
    };
    final encoded = jsonEncode(data);
    final fail =
        (path == 'get_emergency_station_snapshot' && snapshotFailure) ||
        (path == 'customer_payment_displays' && displayFailure);
    await request.drain<void>();
    await beforeReply?.call(path);
    request.response.headers.contentType = ContentType.json;
    if (fail) {
      request.response.statusCode = 503;
      request.response.write(
        jsonEncode({'message': 'fixture unavailable', 'code': 'FIXTURE'}),
      );
    } else {
      request.response.write(encoded);
    }
    await request.response.close();
  }

  void change(
    String table,
    Map<String, dynamic> row, {
    String type = 'UPDATE',
  }) {
    for (final entry in subscriptions.entries) {
      final ids = entry.value.$2
          .where((filter) => filter['table'] == table)
          .map((filter) => filter['id'])
          .toList();
      if (ids.isEmpty) continue;
      entry.value.$1.add(
        jsonEncode({
          'topic': entry.key,
          'event': 'postgres_changes',
          'payload': {
            'ids': ids,
            'data': {
              'schema': 'public',
              'table': table,
              'type': type,
              'commit_timestamp': DateTime.now().toUtc().toIso8601String(),
              'columns': [],
              'record': row,
              'old_record': {},
              'errors': null,
            },
          },
        }),
      );
    }
  }

  void channelError() {
    for (final entry in subscriptions.entries) {
      entry.value.$1.add(
        jsonEncode({'topic': entry.key, 'event': 'phx_error', 'payload': {}}),
      );
    }
  }

  Future<void> close() async {
    await client.removeAllChannels();
    _closing = true;
    await client.dispose();
    for (final peer in peers) {
      await peer.close();
    }
    await server.close(force: true);
  }
}

Future<void> waitUntil(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw StateError('Fixture condition timed out');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}
