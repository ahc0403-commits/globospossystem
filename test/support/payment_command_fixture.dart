import 'dart:convert';

import 'package:globos_pos_system/core/auth/operation_scope_provider.dart';
import 'package:globos_pos_system/core/payments/payment_intent_journal.dart';
import 'package:globos_pos_system/core/utils/operation_contract.dart';
import 'package:globos_pos_system/features/payment/payment_provider.dart';

/// Deterministic atomic adapter for notifier tests. Separate tests exercise the
/// real SQLite and Chromium IndexedDB adapters, including concurrent ownership.
class MemoryPaymentJournal implements PaymentIntentJournal {
  List<Map<String, dynamic>> rows = [];
  @override
  Future<Map<String, dynamic>?> mutate(
    String action,
    Map<String, dynamic> input,
  ) async {
    final copy = (jsonDecode(jsonEncode(rows)) as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    final result = mutatePaymentIntents(copy, action, input);
    rows = copy;
    return result;
  }

  @override
  Future<List<Map<String, dynamic>>> list(
    String project,
    String actor,
    String store,
  ) async => rows
      .where(
        (r) =>
            r['project'] == project &&
            r['actor'] == actor &&
            r['store'] == store,
      )
      .map((r) => Map<String, dynamic>.from(r))
      .toList();
}

OperationScopeSnapshot paymentFixtureScope({
  int generation = 0,
  String actor = 'actor',
  String store = 'store',
}) => OperationScopeSnapshot(
  generation: generation,
  isBound: true,
  scope: OperationScope(
    actorId: actor,
    storeId: store,
    role: 'cashier',
    authorizationRevision: 'fixture-revision',
  ),
);

CashierOrder paymentFixtureOrder({
  String id = 'order',
  int count = 0,
  double due = 100,
}) => CashierOrder(
  orderId: id,
  tableId: 'table',
  tableNumber: '3',
  status: 'serving',
  orderPurpose: 'customer',
  orderSource: 'pos',
  items: const [],
  menuSubtotal: due,
  serviceChargeTotal: 0,
  serviceItemTotal: 0,
  fixedChargeTotal: 0,
  discountTotal: 0,
  vatTotal: 0,
  totalAmount: due,
  paidTotal: 0,
  paymentCount: count,
  remainingDue: due,
  createdAt: DateTime.utc(2026, 11, 1),
);
