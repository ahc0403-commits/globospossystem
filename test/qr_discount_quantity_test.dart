import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/qr_order_service.dart';
import 'package:globos_pos_system/core/menu/menu_choices.dart';

QrMenuItem limited(String id, {int remaining = 1, double price = 50}) =>
    QrMenuItem(
      id: id,
      categoryId: 'existing-discount-category',
      name: id,
      price: price,
      originalPrice: price * 2,
      discountPercent: 50,
      discountRemaining: remaining,
      discountQuantityMenuId: 'registered-dish',
    );

void main() {
  test('one remaining portion quotes a mixed normal/discount price', () {
    final quote = quoteQrDiscountQuantities([
      (item: limited('dish'), quantity: 3),
    ]).single;
    expect(quote.discountQuantity, 1);
    expect(quote.total, 250);
  });

  test('size, choice and takeout lines share one dish balance in order', () {
    final quotes = quoteQrDiscountQuantities([
      (item: limited('small', remaining: 2), quantity: 1),
      (item: limited('large', remaining: 2, price: 75), quantity: 2),
      (item: limited('takeout', remaining: 2), quantity: 1),
    ]);
    expect(quotes.map((quote) => quote.discountQuantity), [1, 1, 0]);
    expect(quotes.map((quote) => quote.total), [50, 225, 100]);
  });

  test('zero quota keeps a dish orderable at normal price', () {
    final item = QrMenuItem.fromJson({
      'id': 'dish',
      'price': 100,
      'original_price': 100,
      'discount_percent': 0,
      'discount_remaining': 0,
      'discount_quantity_menu_id': 'dish',
    });
    final quote = quoteQrDiscountQuantities([(item: item, quantity: 2)]).single;
    expect(quote.discountQuantity, 0);
    expect(quote.total, 200);
  });

  test('unlimited existing discount behavior is preserved', () {
    const item = QrMenuItem(
      id: 'dish',
      categoryId: 'category',
      name: 'Dish',
      price: 50,
      originalPrice: 100,
      discountPercent: 50,
    );
    final quote = quoteQrDiscountQuantities([
      (item: item, quantity: 100),
    ]).single;
    expect(quote.discountQuantity, 100);
    expect(quote.total, 5000);
  });

  test('selected options retain quota and apply the existing discount', () {
    final item = limited('dish').withChoice(
      MenuChoiceSelection('{"unit_price":150,"selected":[],"labels":{}}'),
    );
    expect(item.discountRemaining, 1);
    expect(item.discountQuantityMenuId, 'registered-dish');
    expect(item.price, 75);
    expect(item.originalPrice, 150);
  });

  test(
    'submission carries the reviewed discount allocation for revalidation',
    () {
      const line = QrOrderLine(
        menuItemId: 'dish',
        quantity: 3,
        expectedDiscountQuantity: 1,
        expectedDiscountPercent: 50,
      );
      expect(line.toJson()['expected_discount_quantity'], 1);
      expect(line.toJson()['expected_discount_percent'], 50);
      expect(
        const QrOrderLine(menuItemId: 'other', quantity: 1).toJson(),
        isNot(contains('expected_discount_quantity')),
      );
    },
  );
}
