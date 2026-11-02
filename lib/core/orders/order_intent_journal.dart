import 'dart:convert';

import 'order_intent_journal_native.dart'
    if (dart.library.js_interop) 'order_intent_journal_web.dart'
    as platform;

/// Independent durable order intents. Claim and retirement are atomic across
/// tabs/processes. Neither Auth storage nor the legacy ownerless outbox is used.
abstract class OrderIntentJournal {
  Future<Map<String, dynamic>?> mutate(
    String action,
    Map<String, dynamic> input,
  );
  Future<List<Map<String, dynamic>>> list(
    String project,
    String actor,
    String store,
  );
  static Future<OrderIntentJournal> open() => platform.openOrderIntentJournal();
}

String orderIntentSlot(Map<String, dynamic> r) =>
    jsonEncode([r['project'], r['actor'], r['store'], r['kind'], r['target']]);

const orderIntentIdentityFields = [
  'version',
  'operation',
  'project',
  'actor',
  'store',
  'kind',
  'target',
  'payload',
  'createdAt',
];
const orderIntentTerminalPhases = {'confirmed', 'rejected'};

void validateOrderIntent(Map<String, dynamic> r) {
  if (r['version'] != 1 ||
      !{'create', 'add'}.contains(r['kind']) ||
      r['createdAt'] is! int ||
      (r['createdAt'] as int) <= 0 ||
      r['revision'] is! int ||
      (r['revision'] as int) < 1 ||
      !{
        'prepared',
        'unknown',
        ...orderIntentTerminalPhases,
      }.contains(r['phase']) ||
      r['payload'] is! String ||
      utf8.encode(jsonEncode(r)).length > 256 * 1024) {
    throw const FormatException('ORDER_JOURNAL_INVALID');
  }
  for (final key in ['operation', 'project', 'actor', 'store', 'target']) {
    if (r[key] is! String ||
        (r[key] as String).isEmpty ||
        (r[key] as String).length > 256) {
      throw const FormatException('ORDER_JOURNAL_INVALID');
    }
  }
  final p = jsonDecode(r['payload'] as String);
  if (p is! Map ||
      p['p_store_id'] != r['store'] ||
      p['p_items'] is! List ||
      (p['p_items'] as List).isEmpty ||
      (p['p_items'] as List).length > 500 ||
      p[r['kind'] == 'create' ? 'p_table_id' : 'p_order_id'] != r['target'] ||
      p.containsKey('p_client_mutation_id')) {
    throw const FormatException('ORDER_JOURNAL_PAYLOAD_INVALID');
  }
}

Map<String, dynamic>? mutateOrderIntents(
  List<Map<String, dynamic>> rows,
  String action,
  Map<String, dynamic> input,
) {
  for (final r in rows) {
    validateOrderIntent(r);
  }
  if (utf8.encode(jsonEncode(rows)).length > 4 * 1024 * 1024) {
    throw const FormatException('ORDER_JOURNAL_FULL');
  }
  if (action == 'settle') {
    final operations = input['operations'];
    final rejected = input['rejected'] ?? const [];
    if (operations is! List ||
        operations.length > 100 ||
        operations.any((v) => v is! String) ||
        rejected is! List ||
        rejected.length > 100 ||
        rejected.any((v) => v is! String)) {
      throw const FormatException('ORDER_JOURNAL_SETTLE_INVALID');
    }
    final ids = operations.toSet();
    rows.removeWhere(
      (r) =>
          r['project'] == input['project'] &&
          r['actor'] == input['actor'] &&
          r['store'] == input['store'] &&
          (ids.contains(r['operation']) || r['phase'] == 'confirmed'),
    );
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      if (r['project'] == input['project'] &&
          r['actor'] == input['actor'] &&
          r['store'] == input['store'] &&
          rejected.contains(r['operation']) &&
          !orderIntentTerminalPhases.contains(r['phase'])) {
        rows[i] = {
          ...r,
          'phase': 'rejected',
          'revision': (r['revision'] as int) + 1,
        };
      }
    }
    return null;
  }
  final candidate = Map<String, dynamic>.from(input['record'] as Map);
  validateOrderIntent(candidate);
  final slot = orderIntentSlot(candidate);
  final index = rows.indexWhere((r) => orderIntentSlot(r) == slot);
  final existing = index < 0 ? null : rows[index];
  if (action == 'claim') {
    if (existing != null) return Map.from(existing);
    if (candidate['phase'] != 'prepared' ||
        candidate['revision'] != 1 ||
        rows.any((r) => r['operation'] == candidate['operation'])) {
      throw StateError('ORDER_JOURNAL_CONFLICT');
    }
    if (rows.length >= 100) throw StateError('ORDER_JOURNAL_FULL');
    rows.add(candidate);
  } else {
    if (existing == null || existing['operation'] != candidate['operation']) {
      throw StateError('ORDER_JOURNAL_CONFLICT');
    }
    for (final key in orderIntentIdentityFields) {
      if (candidate[key] != existing[key]) {
        throw StateError('ORDER_JOURNAL_IDENTITY_CHANGED');
      }
    }
    if (input['expectedRevision'] != existing['revision']) {
      return Map.from(existing);
    }
    if (action == 'retire') {
      if (!orderIntentTerminalPhases.contains(existing['phase'])) {
        throw StateError('ORDER_JOURNAL_UNRESOLVED');
      }
      rows.removeAt(index);
      return null;
    }
    if (action != 'update' ||
        candidate['revision'] != (existing['revision'] as int) + 1 ||
        !orderIntentTransitionAllowed(
          existing['phase'] as String,
          candidate['phase'] as String,
        )) {
      throw StateError('ORDER_JOURNAL_TRANSITION');
    }
    rows[index] = candidate;
  }
  if (utf8.encode(jsonEncode(rows)).length > 4 * 1024 * 1024) {
    throw StateError('ORDER_JOURNAL_FULL');
  }
  return Map.from(candidate);
}

bool orderIntentTransitionAllowed(String from, String to) => switch (from) {
  'prepared' => {'unknown', 'confirmed', 'rejected'}.contains(to),
  'unknown' => orderIntentTerminalPhases.contains(to),
  _ => false,
};
