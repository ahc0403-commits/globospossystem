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

  test('floor and tray tickets lead with large floor table header', () async {
    const ticket = PrintTicket(
      ticket: 'floor',
      floorLabel: '2F',
      tableNumber: 'T07',
      ticketCode: 'abc12345',
      batchNo: 2,
      printedReason: 'added_items',
      printedAt: '2026-07-06T12:00:00+07:00',
      items: [
        PrintTicketItem(
          label: 'Phở bò',
          quantity: 2,
          notes: 'No onion',
          supplemental: true,
        ),
      ],
    );

    final floorBytes = await ReceiptBuilder.buildFloorTicket(ticket);
    final trayBytes = await ReceiptBuilder.buildTrayLabel(ticket);

    final floorText = String.fromCharCodes(floorBytes);
    final trayText = String.fromCharCodes(trayBytes);

    expect(floorText.indexOf('2F / T07'), lessThan(floorText.indexOf('FLOOR')));
    expect(trayText.indexOf('2F / T07'), lessThan(trayText.indexOf('TRAY')));
    expect(floorText, contains('*** ADDED ITEMS (batch 2) ***'));
    expect(floorText, contains('Pho bo'));
    expect(floorText, contains('No onion'));
    expect(trayText, contains('DUMBWAITER'));
    expect(floorBytes, contains(0x1d));
    expect(floorBytes, contains(0x56));
  });

  test('print ticket payload preserves DB labels and defaults', () {
    final ticket = PrintTicket.fromPayload({
      'ticket': 'kitchen',
      'floor_label': '3F',
      'table_number': 'T11',
      'ticket_code': 'feedface',
      'batch_no': '3',
      'printed_reason': 'serving',
      'at': '2026-07-06T12:10:00+07:00',
      'items': [
        {'label': 'Bún chả', 'qty': '1', 'supplemental': 'true'},
      ],
    });

    expect(ticket.ticket, 'kitchen');
    expect(ticket.floorLabel, '3F');
    expect(ticket.tableNumber, 'T11');
    expect(ticket.batchNo, 3);
    expect(ticket.items.single.label, 'Bún chả');
    expect(ticket.items.single.quantity, 1);
    expect(ticket.items.single.supplemental, isTrue);
  });
}
