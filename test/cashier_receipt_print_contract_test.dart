import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('cashier receipt printing always uses the configured receipt queue', () {
    final cashier = readRepoFile('lib/features/cashier/cashier_screen.dart');

    expect(cashier, contains('enqueueReceiptPrintJob'));
    expect(cashier, isNot(contains('printerProvider.notifier).print(bytes)')));
    expect(cashier, isNot(contains('ReceiptBuilder.buildPaymentReceipt')));
    expect(cashier, contains('await _printReceipt('));
    expect(cashier, contains('cashTender: cashTender'));
  });
}
