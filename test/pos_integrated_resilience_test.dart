import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/payment_service.dart';
import 'package:globos_pos_system/core/services/qc_service.dart';
import 'package:globos_pos_system/features/payment/payment_provider.dart';
import 'package:globos_pos_system/features/qc/qc_provider.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/kds_realtime_sync.dart';

class _Qc extends QcService {
  final requests = <String, Completer<List<Map<String, dynamic>>>>{};
  @override
  Future<List<Map<String, dynamic>>> fetchTemplates(String storeId) =>
      (requests[storeId] = Completer<List<Map<String, dynamic>>>()).future;
}

class _Payments extends PaymentService {
  @override
  Future<Map<String, dynamic>> processPayment({
    required String orderId,
    required String storeId,
    required double amount,
    required String method,
  }) async => {'id': 'committed'};
}

class _Cashier extends PaymentNotifier {
  _Cashier() : super(payments: _Payments());
  final refresh = Completer<void>();
  @override
  Future<void> loadOrders(String storeId) => refresh.future;
}

void main() {
  test(
    'committed payment returns while its follow-up read is still pending',
    () async {
      final cashier = _Cashier();
      final result = await cashier
          .processPayment('store', 'order', 100, 'CASH')
          .timeout(const Duration(seconds: 1));
      expect(result?['id'], 'committed');
      // ignore: invalid_use_of_protected_member
      expect(cashier.state.paymentSuccess, isTrue);
      cashier.refresh.complete();
      cashier.dispose();
    },
  );

  test('QC store switch ignores an older response and late disposal', () async {
    final service = _Qc();
    final notifier = QcTemplateNotifier(service: service);
    final a = notifier.loadTemplates('A');
    final b = notifier.loadTemplates('B');
    service.requests['B']!.complete([
      {'id': 'B'},
    ]);
    await b;
    service.requests['A']!.complete([
      {'id': 'A'},
    ]);
    await a;
    // ignore: invalid_use_of_protected_member
    expect(notifier.state.templates.single['id'], 'B');
    final c = notifier.loadTemplates('C');
    notifier.dispose();
    service.requests['C']!.complete([]);
    await c;
  });

  test(
    'KDS rejects queue overflow without starting extra physical reads',
    () async {
      final coordinator = KdsReadCoordinator(maxPending: 2);
      final gate = Completer<int>();
      var calls = 0;
      Future<int> read() {
        calls++;
        return gate.future;
      }

      final a = coordinator.run(read);
      final b = coordinator.run(read);
      await expectLater(coordinator.run(read), throwsStateError);
      expect(calls, 1);
      gate.complete(1);
      expect(await a, 1);
      expect(await b, 1);
      expect(calls, 2);
    },
  );

  test('runtime features cannot import the application bootstrap', () {
    final violations = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (f) => f.path.endsWith('.dart') && !f.path.endsWith('/main.dart'),
        )
        .where(
          (f) => RegExp(
            r'''import\s+['"][^'"]*main\.dart['"]''',
          ).hasMatch(f.readAsStringSync()),
        )
        .map((f) => f.path)
        .toList();
    expect(violations, isEmpty);
  });
}
