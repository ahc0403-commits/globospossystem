import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../services/payment_service.dart';
import '../utils/operation_contract.dart';
import 'payment_intent_journal.dart';
import 'payment_method_contract.dart';

class PaymentRecoveryResult {
  const PaymentRecoveryResult(
    this.record,
    this.status, {
    this.payment,
    this.error,
  });
  final Map<String, dynamic> record;
  final CommandStatus status;
  final Map<String, dynamic>? payment;
  final Object? error;
}

/// No automatic charge retries. Unknown intents block all alternative payment
/// paths until an original receipt or the atomic cancellation barrier resolves
/// them. Auth/scope and immutable price/version are supplied by the caller.
class PaymentCommandCoordinator {
  PaymentCommandCoordinator(this.journal, this.service);
  final PaymentIntentJournal journal;
  final PaymentService service;

  Map<String, dynamic> intent({
    required String project,
    required String actor,
    required String store,
    required String order,
    required double amount,
    required String method,
    required int expectedCount,
    String? tableNumber,
  }) => {
    'version': 1,
    'operation': const Uuid().v4(),
    'project': project,
    'actor': actor,
    'store': store,
    'order': order,
    'amount': amount,
    'method': normalizePaymentMethodInput(method),
    'expectedCount': expectedCount,
    'full': true,
    if (tableNumber != null) 'tableNumber': tableNumber,
    'createdAt': DateTime.now().toUtc().millisecondsSinceEpoch,
    'revision': 1,
    'phase': 'prepared',
  };

  Future<PaymentRecoveryResult> execute(
    Map<String, dynamic> candidate, {
    required bool Function() isCurrent,
  }) async {
    _guard(isCurrent);
    var record = (await journal.mutate('claim', {'record': candidate}))!;
    _guard(isCurrent);
    if (record['phase'] != 'prepared') {
      return reconcileOne(record, isCurrent: isCurrent);
    }
    final sender = const Uuid().v4();
    final updated = {
      ...record,
      'phase': 'sending',
      'revision': (record['revision'] as int) + 1,
      'sender': sender,
    };
    record = (await journal.mutate('update', {
      'record': updated,
      'expectedRevision': record['revision'],
    }))!;
    // A failed CAS returns the existing record. A unique sender distinguishes
    // the winner even when both tabs proposed the same phase/revision.
    if (record['sender'] != sender || record['phase'] != 'sending') {
      return reconcileOne(record, isCurrent: isCurrent);
    }
    try {
      _guard(isCurrent);
      final payment = await service.processSinglePaymentCommand(
        operationId: record['operation'] as String,
        orderId: record['order'] as String,
        storeId: record['store'] as String,
        amount: (record['amount'] as num).toDouble(),
        method: record['method'] as String,
        expectedPaymentCount: record['expectedCount'] as int,
        requireFullPayment: true,
        isCurrent: isCurrent,
      );
      // Once the server confirms, storage/cleanup failure cannot relabel it.
      return _confirmed(record, payment);
    } catch (error) {
      if (_definitelyRejected(error)) {
        final rejected = await _phaseBestEffort(record, 'rejected');
        return PaymentRecoveryResult(
          rejected,
          CommandStatus.rejected,
          error: error,
        );
      }
      final unknown = await _phaseBestEffort(record, 'unknown');
      return PaymentRecoveryResult(
        unknown,
        CommandStatus.unknown,
        error: error,
      );
    }
  }

  Future<PaymentRecoveryResult> reconcileOne(
    Map<String, dynamic> record, {
    required bool Function() isCurrent,
  }) async {
    if (record['phase'] == 'confirmed' && record['payment'] is Map) {
      return _confirmed(
        record,
        Map<String, dynamic>.from(record['payment'] as Map),
      );
    }
    if (record['phase'] == 'cancelled' || record['phase'] == 'rejected') {
      return PaymentRecoveryResult(record, CommandStatus.rejected);
    }
    try {
      _guard(isCurrent);
      final rows = await service.getPaymentCommandReceipts(
        storeId: record['store'] as String,
        operationIds: [record['operation'] as String],
        isCurrent: isCurrent,
      );
      if (rows.isNotEmpty) {
        return _confirmed(
          record,
          Map<String, dynamic>.from(rows.single['result'] as Map),
        );
      }
      // Absence is not proof of failure; the original write may still arrive.
      return PaymentRecoveryResult(record, CommandStatus.unknown);
    } catch (error) {
      return PaymentRecoveryResult(record, CommandStatus.unknown, error: error);
    }
  }

  Future<PaymentRecoveryResult> cancel(
    Map<String, dynamic> record, {
    required bool Function() isCurrent,
  }) async {
    _guard(isCurrent);
    if (paymentIntentTerminalPhases.contains(record['phase'])) {
      return reconcileOne(record, isCurrent: isCurrent);
    }
    try {
      if (record['phase'] != 'cancelling') {
        record = await _phase(record, 'cancelling');
      }
      if (record['phase'] != 'cancelling') {
        return reconcileOne(record, isCurrent: isCurrent);
      }
      _guard(isCurrent);
      final response = await service.cancelSinglePaymentCommand(
        operationId: record['operation'] as String,
        orderId: record['order'] as String,
        storeId: record['store'] as String,
        isCurrent: isCurrent,
      );
      if (response['status'] == 'confirmed') {
        return _confirmed(
          record,
          Map<String, dynamic>.from(response['result'] as Map),
        );
      }
      final cancelled = await _phaseBestEffort(record, 'cancelled');
      return PaymentRecoveryResult(cancelled, CommandStatus.rejected);
    } catch (error) {
      return PaymentRecoveryResult(record, CommandStatus.unknown, error: error);
    }
  }

  Future<List<Map<String, dynamic>>> pending(
    String project,
    String actor,
    String store,
  ) => journal.list(project, actor, store);

  Future<void> retire(Map<String, dynamic> record) async {
    await journal.mutate('retire', {
      'record': record,
      'expectedRevision': record['revision'],
    });
  }

  Future<Map<String, dynamic>> _phase(
    Map<String, dynamic> record,
    String phase, {
    Map<String, dynamic>? payment,
  }) async {
    // Bounded CAS retries update only local metadata; no business RPC repeats.
    for (var attempt = 0; attempt < 3; attempt++) {
      if (record['phase'] == phase ||
          paymentIntentTerminalPhases.contains(record['phase'])) {
        return record;
      }
      final next = {
        ...record,
        'phase': phase,
        'revision': (record['revision'] as int) + 1,
        if (payment != null) 'payment': payment,
      };
      final result = (await journal.mutate('update', {
        'record': next,
        'expectedRevision': record['revision'],
      }))!;
      if (result['revision'] == next['revision'] && result['phase'] == phase) {
        return result;
      }
      record = result;
    }
    throw StateError('PAYMENT_JOURNAL_BUSY');
  }

  Future<Map<String, dynamic>> _phaseBestEffort(
    Map<String, dynamic> record,
    String phase, {
    Map<String, dynamic>? payment,
  }) async {
    try {
      return await _phase(record, phase, payment: payment);
    } catch (_) {
      return record;
    }
  }

  Future<PaymentRecoveryResult> _confirmed(
    Map<String, dynamic> record,
    Map<String, dynamic> payment,
  ) async {
    final persisted = await _phaseBestEffort(
      record,
      'confirmed',
      payment: payment,
    );
    return PaymentRecoveryResult(
      persisted,
      CommandStatus.confirmed,
      payment: payment,
    );
  }

  static void _guard(bool Function() isCurrent) {
    if (!isCurrent()) throw StateError('PAYMENT_COMMAND_SCOPE_CHANGED');
  }

  static bool _definitelyRejected(Object error) =>
      error is PostgrestException &&
      (error.code == '42501' || error.code == 'P0001' || error.code == '22023');
}
