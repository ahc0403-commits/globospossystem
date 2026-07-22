import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/cash_tender.dart';

void main() {
  test('calculates change without changing the payment due', () {
    const tender = CashTender(amountDue: 345000, receivedAmount: 400000);

    expect(tender.isSufficient, isTrue);
    expect(tender.changeAmount, 55000);
    expect(tender.amountDue, 345000);
  });

  test('rejects insufficient cash and parses formatted VND input', () {
    final received = parseCashAmount('400.000 ₫');
    final tender = CashTender(amountDue: 450000, receivedAmount: received!);

    expect(received, 400000);
    expect(tender.isSufficient, isFalse);
  });
}
