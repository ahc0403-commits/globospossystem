import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/hardware/receipt_builder.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('payment receipt emits ESC/POS payload with cut command', () async {
    final bytes = await ReceiptBuilder.buildPaymentReceipt(
      restaurantName: 'GLOBOS POS',
      tableNumber: 'A1',
      items: const [
        ReceiptItem(name: 'Cà phê sữa đá', quantity: 2, unitPrice: 25000),
      ],
      totalAmount: 50000,
      paymentMethod: 'cash',
      paidAt: DateTime.utc(2026, 5, 18, 10, 30),
    );

    expect(bytes, isNotEmpty);
    final text = String.fromCharCodes(bytes);
    expect(text, contains('GLOBOSVN POS'));
    expect(text, contains('Ca phe sua da'));
    expect(text, contains('VND'));
    expect(bytes, contains(0x1d));
    expect(bytes, contains(0x56));
  });

  test('service receipts include non-revenue service note', () async {
    final bytes = await ReceiptBuilder.buildPaymentReceipt(
      restaurantName: 'GLOBOS POS',
      tableNumber: 'SVC',
      items: const [
        ReceiptItem(name: 'Staff meal', quantity: 1, unitPrice: 10000),
      ],
      totalAmount: 10000,
      paymentMethod: 'service',
      paidAt: DateTime.utc(2026, 5, 18, 10, 30),
      isService: true,
    );

    final text = String.fromCharCodes(bytes);
    expect(text, contains('Service Provision'));
    expect(text, contains('not counted in revenue'));
  });
}
