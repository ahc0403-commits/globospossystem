import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('qr order route is public and token scoped', () {
    final router = readRepoFile('lib/core/router/app_router.dart');
    final service = readRepoFile('lib/core/services/qr_order_service.dart');

    expect(router, contains("path.startsWith('/qr/')"));
    expect(router, contains("path: '/qr/:token'"));
    expect(router, contains('QrOrderScreen(token:'));
    expect(service, contains("'qr_get_menu'"));
    expect(service, contains("'qr_place_order'"));
    expect(service, contains("'p_token': token"));
    expect(service, contains("'p_client_order_id': clientOrderId"));
    expect(service, contains("'menu_item_id': menuItemId"));
    expect(service, contains("'quantity': quantity"));
  });

  test('qr customer screen is order-only with cashier payment copy', () {
    final screen = readRepoFile('lib/features/qr_order/qr_order_screen.dart');

    expect(screen, contains("Key('qr_order_screen')"));
    expect(screen, contains("Key('qr_confirm_dialog')"));
    expect(screen, contains("Key('qr_confirm_submit')"));
    expect(screen, contains('주문이 접수되었습니다'));
    expect(screen, contains('직원이 주문확인서를 가져다 드립니다'));
    expect(screen, contains('결제는 식사 후 캐셔에서 진행해 주세요'));
    expect(screen, contains('Payment is made at the cashier after your meal'));
    expect(screen, contains('Please pay at the cashier after your meal'));
    expect(screen, contains('clientOrderId'));
    expect(screen, contains('const Uuid()'));
    expect(screen, contains('quantity.clamp(1, 20)'));
    expect(screen, isNot(contains('결제 완료')));
    expect(screen, isNot(contains('Payment complete')));
    expect(screen, isNot(contains('PaymentService')));
    expect(screen, isNot(contains('paymentProvider')));
    expect(screen, isNot(contains('processPayment')));
  });

  test('qr screen maps server guards to customer-safe errors', () {
    final screen = readRepoFile('lib/features/qr_order/qr_order_screen.dart');

    expect(screen, contains('QR_TOKEN_INVALID'));
    expect(screen, contains('QR_ORDER_PAYMENT_IN_PROGRESS'));
    expect(screen, contains('QR_TOO_FREQUENT'));
    expect(screen, contains('QR_MENU_ITEM_UNAVAILABLE'));
    expect(screen, contains('QR_ITEMS_INVALID'));
    expect(screen, contains('Please call staff'));
    expect(screen, contains('Network error. Please retry with the same cart.'));
  });
}
