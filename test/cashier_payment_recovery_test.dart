import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/auth/operation_scope_provider.dart';
import 'package:globos_pos_system/core/payments/payment_command_coordinator.dart';
import 'package:globos_pos_system/core/services/payment_service.dart';
import 'package:globos_pos_system/features/payment/payment_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'support/payment_command_fixture.dart';

class _Service extends PaymentService {
  final confirmed = Completer<void>();
  var lost = true, charges = 0, alternativeCharges = 0;
  Map<String, dynamic>? receipt;
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
    expect(isCurrent(), isTrue);
    charges++;
    receipt = {
      'operation_id': operationId,
      'result': {
        'id': 'payment',
        'order_id': orderId,
        'restaurant_id': storeId,
      },
    };
    if (lost) throw TimeoutException('Response lost after commit');
    await confirmed.future;
    return Map<String, dynamic>.from(receipt!['result'] as Map);
  }

  @override
  Future<List<Map<String, dynamic>>> getPaymentCommandReceipts({
    required String storeId,
    required List<String> operationIds,
    bool Function()? isCurrent,
  }) async => receipt == null ? [] : [receipt!];
  @override
  Future<Map<String, dynamic>> processNonRevenuePayment({
    required String orderId,
    required String storeId,
    required double amount,
    required String type,
    required String reason,
    String? staffName,
    required String managerPin,
  }) async {
    alternativeCharges++;
    return {'id': 'other'};
  }

  @override
  Future<List<Map<String, dynamic>>> processPaymentSplits({
    required String orderId,
    required String storeId,
    required double orderTotal,
    required List<PaymentSplitInput> splits,
  }) async {
    alternativeCharges++;
    return [];
  }

  @override
  Future<Map<String, dynamic>> processCombinedTablePayment({
    required String storeId,
    required List<CombinedOrderPaymentInput> orders,
    required String method,
  }) async {
    alternativeCharges++;
    return {};
  }
}

class _Cashier extends PaymentNotifier {
  _Cashier(
    SupabaseClient client,
    _Service service,
    MemoryPaymentJournal journal,
    OperationScopeSnapshot Function() scope,
  ) : super(
        client: client,
        payments: service,
        commands: PaymentCommandCoordinator(journal, service),
        scope: scope,
      );
  @override
  Future<void> loadOrders(String storeId) async {}
}

void main() {
  late SupabaseClient client;
  late _Service service;
  late MemoryPaymentJournal journal;
  late _Cashier cashier;
  late OperationScopeSnapshot scope;
  setUp(() {
    client = SupabaseClient('https://fixture.invalid', 'fixture');
    service = _Service();
    journal = MemoryPaymentJournal();
    scope = paymentFixtureScope();
    cashier = _Cashier(client, service, journal, () => scope);
    cashier.selectOrder(paymentFixtureOrder());
  });
  tearDown(() async {
    if (cashier.mounted) cashier.dispose();
    await client.dispose();
  });

  test(
    'unknown payment blocks split, combined and non-revenue alternatives',
    () async {
      expect(
        await cashier.processPayment('store', 'order', 100, 'CASH'),
        isNull,
      );
      expect(cashier.state.error, 'PAYMENT_RECOVERY_REQUIRED');
      expect(cashier.state.recoveryRecords, hasLength(1));
      await cashier.processPaymentSplits('store', 'order', 100, [
        const PaymentSplitInput(method: 'CARD', amount: 100),
      ]);
      await cashier.processCombinedTablePayment('store', [
        paymentFixtureOrder(),
      ], 'CARD');
      await cashier.processNonRevenuePayment(
        storeId: 'store',
        orderId: 'order',
        amount: 100,
        type: 'staff_meal',
        reason: 'test',
        managerPin: 'fixture',
      );
      expect(service.charges, 1);
      expect(service.alternativeCharges, 0);
      expect(cashier.state.paymentSuccess, isFalse);
    },
  );
  test(
    'notifier restart and explicit recovery do not collect or print a new payment',
    () async {
      await cashier.processPayment('store', 'order', 100, 'CASH');
      cashier.dispose();
      cashier = _Cashier(client, service, journal, () => scope);
      await cashier.loadPaymentRecovery('store', force: true);
      final pending = cashier.state.recoveryRecords.single;
      await cashier.resolvePaymentRecovery('store', pending);
      expect(cashier.state.recoveryRecords, isEmpty);
      expect(cashier.state.isProcessing, isFalse);
      expect(cashier.state.paymentSuccess, isFalse);
      expect(service.charges, 1);
    },
  );
  test(
    'a later method selection recovers the original receipt without success print callback',
    () async {
      await cashier.processPayment('store', 'order', 100, 'CASH');
      expect(
        await cashier.processPayment('store', 'order', 100, 'CARD'),
        isNull,
      );
      expect(service.charges, 1);
      expect(cashier.state.paymentSuccess, isFalse);
      expect(journal.rows, isEmpty);
    },
  );
  test(
    'confirmed old scope cannot replace new actor UI, even A to B to A',
    () async {
      service.lost = false;
      final result = cashier.processPayment('store', 'order', 100, 'CASH');
      while (service.charges == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      scope = paymentFixtureScope(generation: 1, actor: 'other');
      cashier.resetOperationScope();
      scope = paymentFixtureScope(generation: 2);
      cashier.resetOperationScope();
      cashier.selectOrder(paymentFixtureOrder(id: 'new-order'));
      service.confirmed.complete();
      expect((await result)!['id'], 'payment');
      expect(cashier.state.selectedOrder!.orderId, 'new-order');
      expect(cashier.state.paymentSuccess, isFalse);
      expect(service.charges, 1);
    },
  );
  test('a stale recovery callback after logout is ignored', () async {
    await cashier.processPayment('store', 'order', 100, 'CASH');
    final pending = cashier.state.recoveryRecords.single;
    scope = const OperationScopeSnapshot(
      generation: 1,
      scope: null,
      isBound: true,
    );
    cashier.resetOperationScope();
    await cashier.resolvePaymentRecovery('store', pending);
    expect(cashier.state.error, isNull);
    expect(journal.rows, hasLength(1));
  });
}
