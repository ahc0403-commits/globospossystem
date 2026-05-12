import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('payment detail route is mounted in the tracked app router', () {
    final router = readRepoFile('lib/core/router/app_router.dart');
    final roleRoutes = readRepoFile('lib/core/utils/role_routes.dart');

    expect(router, contains("import '../../features/payment/payment_detail_screen.dart';"));
    expect(router, contains("path: '/payments/:paymentId'"));
    expect(router, contains('PaymentDetailScreen('));
    expect(router, contains("state.pathParameters['paymentId']"));

    expect(roleRoutes, contains("location.startsWith('/payments/')"));
    expect(roleRoutes, contains("'cashier' => location == '/cashier' || location.startsWith('/payments/')"));
    expect(roleRoutes, contains("'admin' => location == '/admin' || location.startsWith('/payments/')"));
  });

  test('cashier success flow hands off to payment detail after tracked post-payment steps', () {
    final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');

    expect(cashier, contains("final paymentId = payment?['id']"));
    expect(cashier, contains('PaymentProofModal('));
    expect(cashier, contains('RedInvoiceModal('));
    expect(cashier, contains("context.go('/payments/\$paymentId')"));
  });

  test('payment detail screen stays read-only and uses tracked payment detail service', () {
    final screen = readRepoFile('lib/features/payment/payment_detail_screen.dart');
    final paymentService = readRepoFile('lib/core/services/payment_service.dart');
    final einvoiceService = readRepoFile('lib/core/services/einvoice_service.dart');

    expect(screen, contains('paymentService.fetchPaymentDetail(widget.paymentId)'));
    expect(screen, contains('Payment Summary'));
    expect(screen, contains('Order Summary'));
    expect(screen, contains('E-Invoice Summary'));
    expect(screen, contains('Proof Summary'));

    expect(paymentService, contains('Future<Map<String, dynamic>?> fetchPaymentDetail(String paymentId)'));
    expect(einvoiceService, isNot(contains('resendInvoiceEmail')));
    expect(screen, isNot(contains('requestRedInvoice(')));
    expect(screen, isNot(contains('inventory_purchase')));
  });
}
