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
    expect(quote.vatTotal, 18900);
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
    expect(quote.vatTotal, 8400);
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
          vatRate: 8,
          payingAmountIncTax: 6480,
        ),
      ],
    );

    expect(quote.menuSubtotal, 108000);
    expect(quote.serviceChargeTotal, 6480);
    expect(quote.vatTotal, 8480);
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

  test(
    'wet tissues add an exact fixed charge outside discount and service charge bases',
    () {
      final quote = calculatePaymentQuote(
        vatPricingMode: vatPricingModeExclusive,
        serviceChargeEnabled: true,
        serviceChargeRate: 10,
        discountTotal: 108000,
        lines: const [
          PaymentQuoteLine(
            unitPrice: 100000,
            quantity: 1,
            status: 'served',
            itemType: 'menu_item',
            vatCategory: 'food',
          ),
          PaymentQuoteLine(
            unitPrice: 3000,
            quantity: 3,
            status: 'ready',
            itemType: 'wet_tissue_charge',
            payingAmountIncTax: 9000,
          ),
        ],
      );

      expect(quote.menuSubtotal, 108000);
      expect(quote.serviceChargeTotal, 10800);
      expect(quote.fixedChargeTotal, 9000);
      expect(quote.discountTotal, 108000);
      expect(quote.payableTotal, 19800);
    },
  );

  test(
    'discount reduces menu subtotal but does not discount service charge',
    () {
      final quote = calculatePaymentQuote(
        vatPricingMode: vatPricingModeExclusive,
        serviceChargeEnabled: true,
        serviceChargeRate: 10,
        discountTotal: 200000,
        lines: const [
          PaymentQuoteLine(
            unitPrice: 100000,
            quantity: 1,
            status: 'served',
            itemType: 'menu_item',
            vatCategory: 'food',
          ),
        ],
      );

      expect(quote.menuSubtotal, 108000);
      expect(quote.serviceChargeTotal, 10800);
      expect(quote.discountTotal, 108000);
      expect(quote.payableTotal, 10800);
    },
  );

  test('service items are excluded from payable and discount bases', () {
    final quote = calculatePaymentQuote(
      vatPricingMode: vatPricingModeExclusive,
      serviceChargeEnabled: true,
      serviceChargeRate: 10,
      discountTotal: 200000,
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
          quantity: 1,
          status: 'served',
          itemType: 'menu_item',
          isServiceItem: true,
          vatCategory: 'food',
        ),
      ],
    );

    expect(quote.menuSubtotal, 108000);
    expect(quote.serviceChargeTotal, 10800);
    expect(quote.serviceItemTotal, 50000);
    expect(quote.discountTotal, 108000);
    expect(quote.payableTotal, 10800);
  });

  test('VAT reflects a 20 percent discount across food and alcohol', () {
    final quote = calculatePaymentQuote(
      vatPricingMode: vatPricingModeExclusive,
      serviceChargeEnabled: false,
      serviceChargeRate: 0,
      discountTotal: 32600,
      lines: const [
        PaymentQuoteLine(
          id: 'food-line',
          unitPrice: 100000,
          quantity: 1,
          status: 'served',
          itemType: 'menu_item',
          vatCategory: 'food',
        ),
        PaymentQuoteLine(
          id: 'alcohol-line',
          unitPrice: 50000,
          quantity: 1,
          status: 'served',
          itemType: 'menu_item',
          vatCategory: 'alcohol',
        ),
      ],
    );

    expect(quote.menuSubtotal, 163000);
    expect(quote.discountTotal, 32600);
    expect(quote.vatTotal, 10400);
    expect(quote.payableTotal, 130400);
  });

  test('menu-scoped promotion discounts only its allocated line', () {
    final quote = calculatePaymentQuote(
      vatPricingMode: vatPricingModeExclusive,
      serviceChargeEnabled: false,
      serviceChargeRate: 0,
      lines: const [
        PaymentQuoteLine(
          id: 'promoted-food',
          unitPrice: 59000,
          quantity: 1,
          status: 'served',
          itemType: 'menu_item',
          vatCategory: 'food',
          discountAmount: 12744,
        ),
        PaymentQuoteLine(
          id: 'regular-food',
          unitPrice: 41000,
          quantity: 1,
          status: 'served',
          itemType: 'menu_item',
          vatCategory: 'food',
        ),
      ],
    );

    expect(quote.menuSubtotal, 108000);
    expect(quote.discountTotal, 12744);
    expect(quote.vatTotal, 7056);
    expect(quote.payableTotal, 95256);
  });

  test(
    'explicit line allocations override stale aggregate discount amount',
    () {
      final quote = calculatePaymentQuote(
        vatPricingMode: vatPricingModeExclusive,
        serviceChargeEnabled: false,
        serviceChargeRate: 0,
        discountTotal: 59000,
        lines: const [
          PaymentQuoteLine(
            id: 'food-line',
            unitPrice: 59000,
            quantity: 1,
            status: 'served',
            itemType: 'menu_item',
            vatCategory: 'food',
            discountAmount: 12744,
          ),
        ],
      );

      expect(quote.menuSubtotal, 63720);
      expect(quote.discountTotal, 12744);
      expect(quote.payableTotal, 50976);
    },
  );
}
