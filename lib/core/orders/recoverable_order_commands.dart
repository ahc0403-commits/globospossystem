import 'dart:convert';
import 'dart:async';

import 'package:supabase_flutter/supabase_flutter.dart';

import 'order_command_rpc.dart';
import 'order_intent_journal.dart';

/// Persists the immutable original actor/request before any order write. The
/// server receipt, rather than a later list refresh, establishes confirmation.
class RecoverableOrderCommands {
  RecoverableOrderCommands(this.source, {OrderIntentJournal? journal})
    : _providedJournal = journal;
  final SupabaseClient source;
  final OrderIntentJournal? _providedJournal;
  Future<OrderIntentJournal>? _openedJournal;
  Future<OrderIntentJournal> get _journal =>
      _openedJournal ??= _providedJournal == null
      ? OrderIntentJournal.open()
      : Future.value(_providedJournal);
  final _pending = <String, (String, Future<dynamic>)>{};
  String get project => source.rest.url;

  Future<dynamic> execute({
    required String kind,
    required String store,
    required String target,
    required String operation,
    required Map<String, dynamic> params,
    bool Function()? isCurrent,
  }) {
    final actor = source.auth.currentUser?.id;
    if (actor == null) throw StateError('ORDER_COMMAND_SCOPE_CHANGED');
    final payload = jsonEncode(params);
    final slot = jsonEncode([project, actor, store, kind, target]);
    final pending = _pending[slot];
    if (pending != null) {
      if (pending.$1 != payload) {
        throw StateError('ORDER_RECOVERY_REVIEW_REQUIRED');
      }
      return pending.$2;
    }
    final future = _execute(
      {
        'version': 1,
        'operation': operation,
        'project': project,
        'actor': actor,
        'store': store,
        'kind': kind,
        'target': target,
        'payload': payload,
        'createdAt': DateTime.now().toUtc().millisecondsSinceEpoch,
        'revision': 1,
        'phase': 'prepared',
      },
      () => source.auth.currentUser?.id == actor && (isCurrent?.call() ?? true),
    );
    _pending[slot] = (payload, future);
    return future.whenComplete(() {
      if (identical(_pending[slot]?.$2, future)) _pending.remove(slot);
    });
  }

  Future<dynamic> _execute(
    Map<String, dynamic> candidate,
    bool Function() current,
  ) async {
    final journal = await _journal;
    if (!current()) throw StateError('ORDER_COMMAND_SCOPE_CHANGED');
    var record = (await journal.mutate('claim', {'record': candidate}))!;
    if (orderIntentTerminalPhases.contains(record['phase'])) {
      await journal.mutate('retire', {
        'record': record,
        'expectedRevision': record['revision'],
      });
      record = (await journal.mutate('claim', {'record': candidate}))!;
    }
    if (record['payload'] != candidate['payload']) {
      throw StateError('ORDER_RECOVERY_REVIEW_REQUIRED');
    }
    if (!current()) throw StateError('ORDER_COMMAND_SCOPE_CHANGED');
    if (record['phase'] == 'prepared') {
      record = (await journal.mutate('update', {
        'record': {
          ...record,
          'phase': 'unknown',
          'revision': (record['revision'] as int) + 1,
        },
        'expectedRevision': record['revision'],
      }))!;
    }
    // A tab/process may send the same immutable operation concurrently; the
    // native atomic receipt makes both resolve to the one original effect.
    try {
      final result = await OrderCommandRpc(source).call(
        record['kind'] == 'create'
            ? OrderCommandRpcKind.create
            : OrderCommandRpcKind.add,
        {
          ...Map<String, dynamic>.from(
            jsonDecode(record['payload'] as String) as Map,
          ),
          'p_client_mutation_id': record['operation'],
        },
        isCurrent: current,
      );
      // Failure to retire local evidence must never turn a confirmed write into
      // a failed order/cart which can be submitted under a fresh operation.
      try {
        await _terminal(journal, record, 'confirmed');
      } catch (_) {
        /* receipt reconciliation retains original */
      }
      return result;
    } on PostgrestException catch (error) {
      if ({
        'P0001',
        '42501',
        '22023',
        '23514',
        'PGRST202',
      }.contains(error.code)) {
        try {
          await _terminal(journal, record, 'rejected');
        } catch (_) {
          /* retain original on storage/race failure */
        }
      }
      rethrow;
    }
  }

  Future<void> _terminal(
    OrderIntentJournal journal,
    Map<String, dynamic> record,
    String phase,
  ) async {
    final terminal = (await journal.mutate('update', {
      'record': {
        ...record,
        'phase': phase,
        'revision': (record['revision'] as int) + 1,
      },
      'expectedRevision': record['revision'],
    }))!;
    if (orderIntentTerminalPhases.contains(terminal['phase'])) {
      await journal.mutate('retire', {
        'record': terminal,
        'expectedRevision': terminal['revision'],
      });
    }
  }

  Future<List<Map<String, dynamic>>> pending(String store) async {
    final actor = source.auth.currentUser?.id;
    if (actor == null) return [];
    return (await _journal).list(project, actor, store);
  }

  /// Bounded batch receipt reads precede a bounded native command batch. No
  /// per-order receipt lookup or full active-order refresh is issued here.
  Future<void> recover(String store, {bool Function()? isCurrent}) async {
    final actor = source.auth.currentUser?.id;
    if (actor == null) return;
    bool current() =>
        source.auth.currentUser?.id == actor && (isCurrent?.call() ?? true);
    final journal = await _journal;
    final records = await journal.list(project, actor, store);
    if (records.isEmpty || !current()) return;
    final rpc = OrderCommandRpc(source);
    final clock = Stopwatch()..start();
    Future<dynamic> boundedCall(
      OrderCommandRpcKind kind,
      Map<String, dynamic> params,
    ) {
      final remaining = const Duration(seconds: 30) - clock.elapsed;
      if (remaining <= Duration.zero) {
        throw TimeoutException('Order recovery deadline');
      }
      return rpc.call(
        kind,
        params,
        isCurrent: current,
        budget: remaining < const Duration(seconds: 15)
            ? remaining
            : const Duration(seconds: 15),
      );
    }

    final confirmed = <String>{};
    for (final kind in ['create', 'add']) {
      final ids = records
          .where((r) => r['kind'] == kind)
          .map((r) => r['operation'])
          .toList();
      if (ids.isEmpty) continue;
      final receipts = await boundedCall(
        kind == 'create'
            ? OrderCommandRpcKind.createReceipts
            : OrderCommandRpcKind.addReceipts,
        {'p_store_id': store, 'p_client_mutation_ids': ids},
      );
      if (receipts is! List ||
          receipts.length > ids.length ||
          receipts.any(
            (r) =>
                r is! Map ||
                r['store_id'] != store ||
                !ids.contains(r['client_mutation_id']),
          )) {
        throw const FormatException('ORDER_RECEIPT_RESPONSE_INVALID');
      }
      for (final r in receipts) {
        confirmed.add(r['client_mutation_id'] as String);
      }
    }
    if (!current()) return;
    await journal.mutate('settle', {
      'project': project,
      'actor': actor,
      'store': store,
      'operations': confirmed.toList(),
    });
    final hasRejected = records.any((r) => r['phase'] == 'rejected');
    final remaining = records
        .where(
          (r) =>
              !confirmed.contains(r['operation']) &&
              !orderIntentTerminalPhases.contains(r['phase']),
        )
        .toList();
    for (var offset = 0; offset < remaining.length;) {
      final batch = <Map<String, dynamic>>[];
      var lines = 0;
      while (offset < remaining.length && batch.length < 20) {
        final r = remaining[offset];
        final p = Map<String, dynamic>.from(
          jsonDecode(r['payload'] as String) as Map,
        );
        final n = (p['p_items'] as List).length;
        if (lines + n > 500 && batch.isNotEmpty) break;
        final command = {
          'kind': r['kind'],
          'operation': r['operation'],
          'params': p,
        };
        if (utf8.encode(jsonEncode([...batch, command])).length > 512 * 1024 &&
            batch.isNotEmpty) {
          break;
        }
        batch.add(command);
        lines += n;
        offset++;
      }
      if (!current()) return;
      final result = await boundedCall(OrderCommandRpcKind.batch, {
        'p_store_id': store,
        'p_commands': batch,
      });
      final requested = batch.map((r) => r['operation']).toSet();
      if (result is! List ||
          result.length != batch.length ||
          result.any(
            (r) =>
                r is! Map ||
                !requested.contains(r['operation']) ||
                !{'confirmed', 'rejected', 'retryable'}.contains(r['status']),
          ) ||
          result.map((r) => r['operation']).toSet().length != result.length) {
        throw const FormatException('ORDER_BATCH_RESPONSE_INVALID');
      }
      final settled = result
          .where((r) => r['status'] == 'confirmed')
          .map((r) => r['operation'])
          .toList();
      await journal.mutate('settle', {
        'project': project,
        'actor': actor,
        'store': store,
        'operations': settled,
        'rejected': result
            .where((r) => r['status'] == 'rejected')
            .map((r) => r['operation'])
            .toList(),
      });
      if (result.any((r) => r['status'] != 'confirmed')) {
        throw StateError('ORDER_RECOVERY_REVIEW_REQUIRED');
      }
    }
    if (hasRejected) throw StateError('ORDER_RECOVERY_REVIEW_REQUIRED');
  }
}
