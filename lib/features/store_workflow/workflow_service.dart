import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

import '../../main.dart';

typedef WorkflowRpc =
    Future<dynamic> Function(String name, Map<String, dynamic> params);

class WorkflowService {
  WorkflowService({WorkflowRpc? rpc})
    : _rpc = rpc ?? ((name, params) => supabase.rpc(name, params: params));
  final WorkflowRpc _rpc;

  Future<Map<String, dynamic>> call(
    String name,
    Map<String, dynamic> params,
  ) async => Map<String, dynamic>.from(await _rpc(name, params) as Map);

  Future<Map<String, dynamic>> admin(
    String storeId, {
    String action = 'load',
    int? revision,
    Map<String, dynamic>? definition,
  }) => call('admin_store_workflow_v1', {
    'p_store_id': storeId,
    'p_action': action,
    'p_expected_revision': revision,
    'p_definition': definition,
  });

  Future<Map<String, dynamic>> snapshot(
    String storeId, {
    Map<String, dynamic>? after,
    bool completed = false,
  }) => call('store_preparation_snapshot_v1', {
    'p_store_id': storeId,
    'p_after': after?['created_at'],
    'p_after_id': after?['id'],
    'p_completed': completed,
  });

  Future<void> acknowledge(
    String storeId,
    String releaseId,
    int pending,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    var device = prefs.getString('workflow_device_v1');
    if (device == null) {
      device = const Uuid().v4();
      await prefs.setString('workflow_device_v1', device);
    }
    await call('store_workflow_device_v1', {
      'p_store_id': storeId,
      'p_device_id': device,
      'p_release_id': releaseId,
      'p_pending_count': pending,
    });
  }

  Future<Map<String, dynamic>> progress(
    String storeId,
    Map<String, dynamic> event,
  ) => call('store_preparation_progress_v1', {'p_store_id': storeId, ...event});
}

/// One durable request at a time, scoped to the authenticated actor and store.
/// An unknown network result keeps the same event ID and exact allocations.
class WorkflowOutbox {
  WorkflowOutbox(this.storeId, this.userId);
  final String storeId;
  final String userId;
  String get key => 'workflow_outbox_v1_${storeId}_$userId';
  Future<Map<String, dynamic>?> read() async {
    final raw = (await SharedPreferences.getInstance()).getString(key);
    if (raw == null) return null;
    final event = jsonDecode(raw);
    if (event is! Map ||
        event['p_event_id'] is! String ||
        event['p_allocations'] is! List) {
      throw const FormatException('WORKFLOW_OUTBOX_INVALID');
    }
    return Map<String, dynamic>.from(event);
  }

  Future<void> save(Map<String, dynamic> event) async {
    if (await read() != null) throw StateError('WORKFLOW_PENDING_ACTION');
    final saved = await (await SharedPreferences.getInstance()).setString(
      key,
      jsonEncode(event),
    );
    if (!saved) throw StateError('WORKFLOW_OUTBOX_SAVE_FAILED');
  }

  Future<void> clear() async {
    final cleared = await (await SharedPreferences.getInstance()).remove(key);
    if (!cleared) throw StateError('WORKFLOW_OUTBOX_CLEAR_FAILED');
  }
}

String workflowText(String language, String ko, String vi, String en) =>
    switch (language) {
      'ko' => ko,
      'vi' => vi,
      _ => en,
    };
