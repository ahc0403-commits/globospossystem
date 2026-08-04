import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/qr_order_service.dart';

void main() {
  test('QR menu parses scheduled promotion and discounted prices', () {
    final menu = QrOrderMenu.fromJson({
      'store_name': 'BunsikClub',
      'table_number': '1',
      'floor_label': '1F',
      'promotion_name': 'Opening',
      'promotion_discount_percent': 30,
      'categories': const <Map<String, dynamic>>[],
      'items': [
        {
          'id': 'menu-1',
          'name': 'Tteokbokki',
          'price': 70000,
          'original_price': 100000,
          'discount_percent': 30,
        },
      ],
    });

    expect(menu.promotionName, 'Opening');
    expect(menu.promotionDiscountPercent, 30);
    expect(menu.items.single.price, 70000);
    expect(menu.items.single.originalPrice, 100000);
    expect(menu.items.single.discountPercent, 30);
  });
}
