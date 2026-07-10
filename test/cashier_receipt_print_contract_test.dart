import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('cashier receipt printing is payment-complete and service-aware', () {
    final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');

    expect(cashier, contains('ReceiptBuilder.buildPaymentReceipt'));
    expect(cashier, contains('printerProvider.notifier).print(bytes)'));
    expect(
      cashier,
      contains('showErrorToast(context, l10n.settingsEnterIpFirst)'),
    );
    expect(cashier, contains('isService: isServicePaymentMethod(method)'));
    expect(
      cashier,
      contains('await _printReceipt(order: selectedOrder, method: method)'),
    );
  });
}
