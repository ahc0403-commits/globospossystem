import 'dart:convert';

import 'payment_intent_journal_native.dart'
    if (dart.library.js_interop) 'payment_intent_journal_web.dart'
    as platform;

/// Financial intents are separate from menu caches, Auth and the KDS outbox.
/// claim/CAS/retire are atomic across tabs or native processes. Storage failure
/// is fail-closed: a payment must never be sent without its original intent.
abstract class PaymentIntentJournal {
  Future<Map<String, dynamic>?> mutate(
    String action,
    Map<String, dynamic> input,
  );
  Future<List<Map<String, dynamic>>> list(
    String project,
    String actor,
    String store,
  );
  static Future<PaymentIntentJournal> open() =>
      platform.openPaymentIntentJournal();
}

String paymentIntentSlot(Map<String, dynamic> r) =>
    jsonEncode([r['project'], r['actor'], r['store'], r['order']]);

const paymentIntentIdentityFields = [
  'version',
  'operation',
  'project',
  'actor',
  'store',
  'order',
  'amount',
  'method',
  'expectedCount',
  'full',
  'createdAt',
  'tableNumber',
];

const paymentIntentTerminalPhases = {'confirmed', 'cancelled', 'rejected'};

void validatePaymentIntent(Map<String, dynamic> r) {
  if (r['tableNumber'] != null &&
      (r['tableNumber'] is! String ||
          (r['tableNumber'] as String).length > 128)) {
    throw const FormatException('PAYMENT_JOURNAL_INVALID');
  }
  if (r['version'] != 1 ||
      r['full'] != true ||
      r['amount'] is! num ||
      !(r['amount'] as num).isFinite ||
      (r['amount'] as num) <= 0 ||
      r['expectedCount'] is! int ||
      (r['expectedCount'] as int) < 0 ||
      r['createdAt'] is! int ||
      (r['createdAt'] as int) <= 0 ||
      r['revision'] is! int ||
      (r['revision'] as int) < 1 ||
      !{
        'prepared',
        'sending',
        'unknown',
        'cancelling',
        ...paymentIntentTerminalPhases,
      }.contains(r['phase']) ||
      utf8.encode(jsonEncode(r)).length > 8192) {
    throw const FormatException('PAYMENT_JOURNAL_INVALID');
  }
  for (final key in [
    'operation',
    'project',
    'actor',
    'store',
    'order',
    'method',
  ]) {
    if (r[key] is! String ||
        (r[key] as String).isEmpty ||
        (r[key] as String).length > 256) {
      throw const FormatException('PAYMENT_JOURNAL_INVALID');
    }
  }
}

/// Shared native/test transaction logic. Browser uses the same contract inside
/// one IndexedDB readwrite transaction; neither adapter does a read/write pair.
Map<String, dynamic>? mutatePaymentIntents(
  List<Map<String, dynamic>> rows,
  String action,
  Map<String, dynamic> input,
) {
  for (final r in rows) {
    validatePaymentIntent(r);
  }
  final candidate = Map<String, dynamic>.from(input['record'] as Map);
  validatePaymentIntent(candidate);
  final slot = paymentIntentSlot(candidate);
  final index = rows.indexWhere((r) => paymentIntentSlot(r) == slot);
  final existing = index < 0 ? null : rows[index];
  if (action == 'claim') {
    if (existing != null) return Map.from(existing);
    if (candidate['phase'] != 'prepared' ||
        candidate['revision'] != 1 ||
        rows.any((r) => r['operation'] == candidate['operation'])) {
      throw StateError('PAYMENT_JOURNAL_CONFLICT');
    }
    if (rows.length >= 100) throw StateError('PAYMENT_JOURNAL_FULL');
    rows.add(candidate);
  } else {
    if (existing == null || existing['operation'] != candidate['operation']) {
      throw StateError('PAYMENT_JOURNAL_CONFLICT');
    }
    for (final key in paymentIntentIdentityFields) {
      if (candidate[key] != existing[key]) {
        throw StateError('PAYMENT_JOURNAL_IDENTITY_CHANGED');
      }
    }
    if (input['expectedRevision'] != existing['revision']) {
      return Map.from(existing);
    }
    if (action == 'retire') {
      if (!paymentIntentTerminalPhases.contains(existing['phase'])) {
        throw StateError('PAYMENT_JOURNAL_UNRESOLVED');
      }
      rows.removeAt(index);
      return null;
    }
    if (action != 'update' ||
        candidate['revision'] != (existing['revision'] as int) + 1 ||
        !paymentIntentTransitionAllowed(
          existing['phase'] as String,
          candidate['phase'] as String,
        )) {
      throw StateError('PAYMENT_JOURNAL_TRANSITION');
    }
    rows[index] = candidate;
  }
  if (utf8.encode(jsonEncode(rows)).length > 256 * 1024) {
    throw StateError('PAYMENT_JOURNAL_FULL');
  }
  return Map.from(candidate);
}

bool paymentIntentTransitionAllowed(String from, String to) => switch (from) {
  'prepared' => {'sending', 'cancelling', 'rejected'}.contains(to),
  'sending' => {'unknown', 'confirmed', 'cancelling', 'rejected'}.contains(to),
  'unknown' => {'confirmed', 'cancelling', 'rejected'}.contains(to),
  'cancelling' => {'confirmed', 'cancelled'}.contains(to),
  _ => false,
};
