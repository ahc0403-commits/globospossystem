import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/payment_command_coordinator.dart';
import 'package:globos_pos_system/core/payments/payment_intent_journal.dart';
import 'package:globos_pos_system/core/payments/payment_intent_journal_native.dart';
import 'package:globos_pos_system/core/services/payment_service.dart';
import 'package:globos_pos_system/core/utils/operation_contract.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Service extends PaymentService {
  int charges = 0, lookups = 0, cancels = 0;
  bool loseResponse = false, loseCancel = false, commit = true;
  Object? rejection;
  final receipts = <String, Map<String, dynamic>>{};
  @override
  Future<Map<String, dynamic>> processSinglePaymentCommand({
    required String operationId,
    required String orderId,
    required String storeId,
    required double amount,
    required String method,
    required int expectedPaymentCount,
    required bool requireFullPayment,
    required bool Function() isCurrent,
  }) async {
    if (rejection != null) throw rejection!;
    expect(isCurrent(), isTrue);
    expect(requireFullPayment, isTrue);
    charges++;
    await Future<void>.delayed(const Duration(milliseconds: 25));
    final payment = {
      'id': 'payment-$charges',
      'order_id': orderId,
      'restaurant_id': storeId,
    };
    if (commit) receipts[operationId] = payment;
    if (loseResponse) {
      throw TimeoutException('Response lost after native commit');
    }
    return payment;
  }

  @override
  Future<List<Map<String, dynamic>>> getPaymentCommandReceipts({
    required String storeId,
    required List<String> operationIds,
    bool Function()? isCurrent,
  }) async {
    expect(isCurrent?.call(), isTrue);
    lookups++;
    return [
      for (final op in operationIds)
        if (receipts[op] != null) {'operation_id': op, 'result': receipts[op]},
    ];
  }

  @override
  Future<Map<String, dynamic>> cancelSinglePaymentCommand({
    required String operationId,
    required String orderId,
    required String storeId,
    required bool Function() isCurrent,
  }) async {
    expect(isCurrent(), isTrue);
    cancels++;
    if (loseCancel) throw TimeoutException('Lost cancellation acknowledgement');
    return {
      'status': receipts.containsKey(operationId) ? 'confirmed' : 'cancelled',
      if (receipts.containsKey(operationId)) 'result': receipts[operationId],
    };
  }
}

class _FailUpdates implements PaymentIntentJournal {
  _FailUpdates(this.base);
  final PaymentIntentJournal base;
  @override
  Future<Map<String, dynamic>?> mutate(
    String action,
    Map<String, dynamic> input,
  ) {
    if (action == 'update' && (input['record'] as Map)['phase'] == 'confirmed') {
      throw StateError('Disk full after commit');
    }
    return base.mutate(action, input);
  }

  @override
  Future<List<Map<String, dynamic>>> list(
    String project,
    String actor,
    String store,
  ) => base.list(project, actor, store);
}

void main() {
  late Directory dir;
  late NativePaymentIntentJournal journal;
  late _Service service;
  late PaymentCommandCoordinator commands;
  Map<String, dynamic> intent({String method = 'CASH'}) => commands.intent(
    project: 'https://fixture.invalid',
    actor: 'actor',
    store: 'store',
    order: 'order',
    amount: 10000,
    method: method,
    expectedCount: 0,
  );
  setUp(() async {
    dir = await Directory.systemTemp.createTemp('owned-payment-recovery-');
    journal = NativePaymentIntentJournal(dir);
    service = _Service();
    commands = PaymentCommandCoordinator(journal, service);
  });
  tearDown(() async {
    await dir.delete(recursive: true);
  });
  test(
    'lost response survives restart and is recovered without a second charge',
    () async {
      service.loseResponse = true;
      final original = intent();
      expect(
        (await commands.execute(original, isCurrent: () => true)).status,
        CommandStatus.unknown,
      );
      final reopened = PaymentCommandCoordinator(
        NativePaymentIntentJournal(dir),
        service,
      );
      final records = await reopened.pending(
        'https://fixture.invalid',
        'actor',
        'store',
      );
      final result = await reopened.reconcileOne(
        records.single,
        isCurrent: () => true,
      );
      expect(result.status, CommandStatus.confirmed);
      expect(result.record['operation'], original['operation']);
      expect(service.charges, 1);
      expect(service.lookups, 1);
    },
  );
  test(
    '20 concurrent owners send exactly one charge, including distinct methods',
    () async {
      final results = await Future.wait(
        List.generate(
          20,
          (n) =>
              PaymentCommandCoordinator(
                NativePaymentIntentJournal(dir),
                service,
              ).execute(
                intent(method: n.isEven ? 'CASH' : 'CARD'),
                isCurrent: () => true,
              ),
        ),
      );
      expect(service.charges, 1);
      expect(results.map((r) => r.record['operation']).toSet(), hasLength(1));
    },
  );
  test('unconfirmed absence never permits new method or operation', () async {
    service.loseResponse = true;
    service.commit = false;
    final original = await commands.execute(intent(), isCurrent: () => true);
    final next = await commands.execute(
      intent(method: 'CARD'),
      isCurrent: () => true,
    );
    expect(next.status, CommandStatus.unknown);
    expect(next.record['operation'], original.record['operation']);
    expect(next.record['method'], 'CASH');
    expect(service.charges, 1);
  });
  test(
    'cancel response loss retains the same cancellation and never charges',
    () async {
      service.loseResponse = true;
      service.commit = false;
      final original = await commands.execute(intent(), isCurrent: () => true);
      service.loseCancel = true;
      final lost = await commands.cancel(
        original.record,
        isCurrent: () => true,
      );
      expect(lost.status, CommandStatus.unknown);
      expect(lost.record['phase'], 'cancelling');
      service.loseCancel = false;
      final done = await commands.cancel(lost.record, isCurrent: () => true);
      expect(done.record['phase'], 'cancelled');
      expect(service.charges, 1);
      expect(service.cancels, 2);
      await commands.retire(done.record);
      expect(
        await commands.pending('https://fixture.invalid', 'actor', 'store'),
        isEmpty,
      );
    },
  );
  test('cancel after commit returns original confirmed payment', () async {
    service.loseResponse = true;
    final lost = await commands.execute(intent(), isCurrent: () => true);
    final cancelled = await commands.cancel(lost.record, isCurrent: () => true);
    expect(cancelled.status, CommandStatus.confirmed);
    expect(service.charges, 1);
  });
  test(
    'storage failure after confirmed RPC cannot turn success into unknown',
    () async {
      commands = PaymentCommandCoordinator(_FailUpdates(journal), service);
      final result = await commands.execute(intent(), isCurrent: () => true);
      expect(result.status, CommandStatus.confirmed);
      expect(result.payment!['id'], 'payment-1');
      expect(
        (await journal.list(
          'https://fixture.invalid',
          'actor',
          'store',
        )).single['phase'],
        'sending',
      );
    },
  );
  test(
    'known SQL rejection is terminal while malformed/transport results remain unknown',
    () async {
      service.rejection = const PostgrestException(
        message: 'PAYMENT_ORDER_CHANGED',
        code: 'P0001',
      );
      final rejected = await commands.execute(intent(), isCurrent: () => true);
      expect(rejected.status, CommandStatus.rejected);
      expect(rejected.record['phase'], 'rejected');
      expect(service.charges, 0);
      await commands.retire(rejected.record);
      service.rejection = const FormatException('Malformed result');
      final unknown = await commands.execute(intent(), isCurrent: () => true);
      expect(unknown.status, CommandStatus.unknown);
      expect(unknown.record['phase'], 'unknown');
    },
  );
  test('scope change before persistence sends nothing', () async {
    await expectLater(
      commands.execute(intent(), isCurrent: () => false),
      throwsStateError,
    );
    expect(service.charges, 0);
    expect(
      await journal.list('https://fixture.invalid', 'actor', 'store'),
      isEmpty,
    );
  });
}
