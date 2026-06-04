import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/payment_total_calculator.dart';

void main() {
  test('exclusive VAT quote matches process_payment gross total math', () {
    final quote = calculatePaymentQuote(
      vatPricingMode: vatPricingModeExclusive,
      serviceChargeEnabled: true,
      serviceChargeRate: 5,
      lines: const [
        PaymentQuoteLine(
          unitPrice: 100000,
          quantity: 1,
          status: 'served',
          itemType: 'menu_item',
          vatCategory: 'food',
        ),
        PaymentQuoteLine(
          unitPrice: 50000,
          quantity: 2,
          status: 'served',
          itemType: 'menu_item',
          vatCategory: 'alcohol',
        ),
      ],
    );

    expect(quote.menuSubtotal, 218000);
    expect(quote.serviceChargeTotal, 10900);
    expect(quote.payableTotal, 228900);
  });

  test('inclusive VAT quote keeps menu price as customer-facing total', () {
    final quote = calculatePaymentQuote(
      vatPricingMode: vatPricingModeInclusive,
      serviceChargeEnabled: true,
      serviceChargeRate: 5,
      lines: const [
        PaymentQuoteLine(
          unitPrice: 108000,
          quantity: 1,
          status: 'served',
          itemType: 'menu_item',
          vatCategory: 'food',
        ),
      ],
    );

    expect(quote.menuSubtotal, 108000);
    expect(quote.serviceChargeTotal, 5400);
    expect(quote.payableTotal, 113400);
  });

  test('existing service charge lines are not generated twice', () {
    final quote = calculatePaymentQuote(
      vatPricingMode: vatPricingModeExclusive,
      serviceChargeEnabled: true,
      serviceChargeRate: 5,
      lines: const [
        PaymentQuoteLine(
          unitPrice: 100000,
          quantity: 1,
          status: 'served',
          itemType: 'menu_item',
          vatCategory: 'food',
        ),
        PaymentQuoteLine(
          unitPrice: 6000,
          quantity: 1,
          status: 'served',
          itemType: 'service_charge',
          payingAmountIncTax: 6480,
        ),
      ],
    );

    expect(quote.menuSubtotal, 108000);
    expect(quote.serviceChargeTotal, 6480);
    expect(quote.payableTotal, 114480);
  });

  test('cancelled lines do not affect payment quote', () {
    final quote = calculatePaymentQuote(
      vatPricingMode: vatPricingModeExclusive,
      serviceChargeEnabled: false,
      serviceChargeRate: 0,
      lines: const [
        PaymentQuoteLine(
          unitPrice: 100000,
          quantity: 1,
          status: 'cancelled',
          itemType: 'menu_item',
          vatCategory: 'food',
        ),
      ],
    );

    expect(quote.payableTotal, 0);
  });
}
