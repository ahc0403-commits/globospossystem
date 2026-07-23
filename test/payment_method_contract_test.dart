import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/payment_method_contract.dart';

void main() {
  test('cashier payment aliases normalize to WeTax payment codes', () {
    expect(normalizePaymentMethodInput('cash'), paymentMethodCash);
    expect(normalizePaymentMethodInput('card'), paymentMethodCreditCard);
    expect(normalizePaymentMethodInput('pay'), paymentMethodOther);
    expect(
      normalizePaymentMethodInput('banktransfer'),
      paymentMethodBankTransfer,
    );
    expect(normalizePaymentMethodInput('service'), paymentMethodService);
  });

  test('proof requirement follows normalized pilot payment categories', () {
    expect(requiresPaymentProof('cash'), isFalse);
    expect(requiresPaymentProof('card'), isTrue);
    expect(requiresPaymentProof('pay'), isTrue);
    expect(requiresPaymentProof(paymentMethodBankTransfer), isTrue);
    expect(requiresPaymentProof('service'), isFalse);
  });

  test('bank transfer is selectable revenue and has a receipt label', () {
    expect(
      cashierSelectablePaymentMethods,
      contains(paymentMethodBankTransfer),
    );
    expect(isRevenuePaymentMethod(paymentMethodBankTransfer), isTrue);
    expect(
      paymentMethodDisplayLabel(paymentMethodBankTransfer),
      'Bank Transfer',
    );
  });
}
