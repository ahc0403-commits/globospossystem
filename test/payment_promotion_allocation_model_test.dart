import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/payment/payment_provider.dart';

void main() {
  test('scheduled promotion parses exact order-item allocations', () {
    final discount = ActiveOrderDiscount.fromJson({
      'id': 'discount-1',
      'discount_type': 'promotion',
      'discount_mode': 'percent',
      'discount_value': 20,
      'discount_amount': 12744,
      'status': 'active',
      'approved_via': 'scheduled_promotion',
      'reason': 'Lunch 20%',
      'coupon_code': 'promotion-1',
      'order_discount_lines': [
        {
          'order_item_id': 'order-item-1',
          'discount_amount': 12744,
          'discount_percent': 20,
        },
      ],
    });

    expect(discount.isScheduledPromotion, isTrue);
    expect(discount.hasLineDiscounts, isTrue);
    expect(discount.lineDiscounts, {'order-item-1': 12744});
    expect(discount.reason, 'Lunch 20%');
  });

  test('manager discount remains distinguishable from scheduled promotion', () {
    final discount = ActiveOrderDiscount.fromJson({
      'id': 'discount-2',
      'discount_type': 'manual',
      'discount_mode': 'amount',
      'discount_value': 59000,
      'discount_amount': 59000,
      'status': 'active',
      'approved_via': 'manager_pin',
      'order_discount_lines': const <Map<String, dynamic>>[],
    });

    expect(discount.isScheduledPromotion, isFalse);
    expect(discount.hasLineDiscounts, isFalse);
    expect(discount.mode, 'amount');
    expect(discount.amount, 59000);
  });
}
