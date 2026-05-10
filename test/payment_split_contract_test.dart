import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/payment_method_contract.dart';
import 'package:globos_pos_system/core/services/payment_service.dart';

void main() {
  test('payment splits must match order total', () {
    final splits = [
      const PaymentSplitInput(method: paymentMethodCash, amount: 40000),
      const PaymentSplitInput(method: paymentMethodMomo, amount: 60000),
    ];

    expect(validatePaymentSplits(splits, 100000), isNull);
  });

  test('payment splits reject invalid totals and methods', () {
    expect(
      validatePaymentSplits([
        const PaymentSplitInput(method: paymentMethodCash, amount: 90000),
      ], 100000),
      isNotNull,
    );
    expect(
      validatePaymentSplits([
        const PaymentSplitInput(method: 'BAD', amount: 100000),
      ], 100000),
      isNotNull,
    );
  });
}
