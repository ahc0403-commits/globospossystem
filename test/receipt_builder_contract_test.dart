import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/hardware/receipt_builder.dart';
import 'package:globos_pos_system/core/utils/floor_label.dart';

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
      legalName: 'CÔNG TY TNHH AKJ INTERNATIONAL',
      taxCode: '0318453298',
      addressLines: const ['69/1A2 Nguyễn Gia Trí'],
      receiptNumber: 'BC-20260721-000123',
      cashierCode: 'EMP001',
      vatAmount: 3703.70,
    );

    expect(bytes, isNotEmpty);
    final text = String.fromCharCodes(bytes);
    expect(text, contains('GLOBOS POS'));
    expect(text, contains('AKJ INTERNATIONAL'));
    expect(text, contains('0318453298'));
    expect(text, contains('PHIEU THANH TOAN'));
    expect(text, contains('BC-20260721-000123'));
    expect(text, isNot(contains('So don')));
    expect(text, contains('Ca phe sua da'));
    expect(text, contains('VND'));
    expect(text, contains('VAT (da gom)'));
    expect(text, contains('3,703 VND'));
    expect(text, isNot(contains('***')));
    expect(text, contains('CHUYEN KHOAN'));
    expect(text, contains('WOORI BANK - 100202042976'));
    expect(text, contains('AHN HYOCHANG'));
    expect(bytes, contains(0x76));
    expect(bytes, contains(0x1d));
    expect(bytes, contains(0x56));
  });

  test(
    'payment receipt prints zero VAT numerically when VAT is absent',
    () async {
      final text = String.fromCharCodes(
        await ReceiptBuilder.buildPaymentReceipt(
          restaurantName: 'GLOBOS POS',
          tableNumber: 'A1',
          items: const [
            ReceiptItem(name: 'Staff meal', quantity: 1, unitPrice: 10000),
          ],
          totalAmount: 10000,
          paymentMethod: 'service',
          paidAt: DateTime.utc(2026, 8, 11, 10, 30),
          isService: true,
        ),
      );

      expect(text, contains('VAT (da gom)'));
      expect(text, contains('0 VND'));
      expect(text, isNot(contains('***')));
    },
  );

  test(
    'delivery driver receipt includes address and charged Grab total',
    () async {
      final bytes = await ReceiptBuilder.buildDeliveryDriverReceipt(
        restaurantName: 'Bunsik Club',
        referenceCode: 'D1234ABCD',
        customerName: 'Nguyễn Văn An',
        customerPhone: '+84901234567',
        formattedAddress: '123 Nguyễn Huệ, Quận 1, TP.HCM',
        detailAddress: 'Tầng 4, phòng 401',
        items: const [
          ReceiptItem(name: 'Cơm gà', quantity: 2, unitPrice: 50000),
        ],
        menuTotal: 100000,
        serviceChargeTotal: 10000,
        deliveryFeeTotal: 25000,
        finalTotal: 135000,
        printedAt: DateTime.utc(2026, 9, 1, 10, 30),
      );

      final text = String.fromCharCodes(bytes);
      expect(text, contains('PHIEU GIAO HANG'));
      expect(text, contains('DA THANH TOAN'));
      expect(text, contains('D1234ABCD'));
      expect(text, contains('Nguyen Van An'));
      expect(text, contains('+84901234567'));
      expect(text, contains('123 Nguyen Hue, Quan 1, TP.HCM'));
      expect(text, contains('Tang 4, phong 401'));
      expect(text, contains('Com ga'));
      expect(text, contains('Phi giao hang Grab'));
      expect(text, contains('25,000 VND'));
      expect(text, contains('TONG DA THANH TOAN'));
      expect(text, contains('135,000 VND'));
      expect(text, contains('Khach can tra: 0 VND'));
      expect(text, contains('KHONG THU THEM TIEN CUA KHACH'));
      expect(text, isNot(contains('WOORI BANK')));
      expect(text, isNot(contains('PHIEU THANH TOAN')));
      expect(bytes, contains(0x1d));
      expect(bytes, contains(0x56));
    },
  );

  test('queued delivery driver receipt reads its isolated payload', () {
    final receipt = QueuedDeliveryDriverReceipt.fromPayload({
      'restaurant_name': 'GLOBOS POS',
      'reference_code': 'D9999TEST',
      'customer_name': 'Customer',
      'customer_phone': '0901234567',
      'formatted_address': 'Main address',
      'detail_address': 'Unit 2',
      'items': const [
        {'label': 'Menu', 'quantity': '2', 'unit_price': '50000'},
      ],
      'menu_total': '100000',
      'service_charge_total': 10000,
      'delivery_fee_total': '25000',
      'final_total': 135000,
      'at': '2026-09-01T10:30:00+07:00',
    });

    expect(receipt.referenceCode, 'D9999TEST');
    expect(receipt.formattedAddress, 'Main address');
    expect(receipt.items.single.quantity, 2);
    expect(receipt.items.single.unitPrice, 50000);
    expect(receipt.deliveryFeeTotal, 25000);
    expect(receipt.finalTotal, 135000);
  });

  test(
    'frozen print agent fallback renders the dedicated driver slip',
    () async {
      final ticket = PrintTicket.fromPayload({
        'ticket': 'delivery_driver_receipt',
        'restaurant_name': 'GLOBOS POS',
        'reference_code': 'D9999TEST',
        'customer_name': 'Customer',
        'customer_phone': '0901234567',
        'formatted_address': 'Main address',
        'detail_address': 'Unit 2',
        'items': const [
          {'label': 'Menu', 'quantity': 2, 'unit_price': 50000},
        ],
        'menu_total': 100000,
        'service_charge_total': 10000,
        'delivery_fee_total': 25000,
        'final_total': 135000,
        'at': '2026-09-01T10:30:00+07:00',
      });

      final text = String.fromCharCodes(
        await ReceiptBuilder.buildKitchenTicket(ticket),
      );

      expect(text, contains('PHIEU GIAO HANG'));
      expect(text, contains('Main address'));
      expect(text, contains('Phi giao hang Grab'));
      expect(text, contains('135,000 VND'));
      expect(text, isNot(contains('PHIEU BEP')));
    },
  );

  test('queued payment receipt reads VAT amount from print payload', () {
    final receipt = QueuedPaymentReceipt.fromPayload({
      'restaurant_name': 'GLOBOS POS',
      'table_number': 'A1',
      'items': const [],
      'total_amount': 50000,
      'payment_method': 'cash',
      'vat_amount': '3703.70',
    });

    expect(receipt.vatAmount, 3703.70);
  });

  test('queued combined receipt prefers group totals over trigger fields', () {
    final receipt = QueuedPaymentReceipt.fromPayload({
      'is_combined': true,
      'restaurant_name': 'GLOBOS POS',
      'table_number': 'A1, B2',
      'items': const [],
      'total_amount': 150000,
      'payment_method': 'other',
      'receipt_number': 'SINGLE-ORDER-VALUE',
      'subtotal_amount': 50000,
      'vat_amount': 4000,
      'received_amount': 50000,
      'combined_receipt_number': 'COMBINED-GROUP-VALUE',
      'combined_subtotal_amount': 140000,
      'combined_discount_amount': 5000,
      'combined_vat_amount': 11000,
      'combined_received_amount': 150000,
      'combined_change_amount': 0,
    });

    expect(receipt.tableNumber, 'A1, B2');
    expect(receipt.receiptNumber, 'COMBINED-GROUP-VALUE');
    expect(receipt.subtotalAmount, 140000);
    expect(receipt.discountAmount, 5000);
    expect(receipt.vatAmount, 11000);
    expect(receipt.receivedAmount, 150000);
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
    expect(text, contains('Phuc vu noi bo'));
    expect(text, contains('Khong tinh doanh thu'));
    expect(text, isNot(contains('CHUYEN KHOAN')));
    expect(text, isNot(contains('100202042976')));
  });

  test('bank transfer receipts use the bank transfer method label', () async {
    final bytes = await ReceiptBuilder.buildPaymentReceipt(
      restaurantName: 'GLOBOS POS',
      tableNumber: 'A1',
      items: const [ReceiptItem(name: 'Kimbap', quantity: 1, unitPrice: 30000)],
      totalAmount: 30000,
      paymentMethod: 'bank_transfer',
      paidAt: DateTime.utc(2026, 8, 5, 10, 30),
    );

    expect(String.fromCharCodes(bytes), contains('Phuong thuc : Chuyen khoan'));
  });

  test('service item lines are excluded from customer receipt body', () async {
    final bytes = await ReceiptBuilder.buildPaymentReceipt(
      restaurantName: 'GLOBOS POS',
      tableNumber: 'A1',
      items: const [
        ReceiptItem(name: 'Pho bo', quantity: 1, unitPrice: 30000),
        ReceiptItem(
          name: 'Service dessert',
          quantity: 2,
          unitPrice: 15000,
          isServiceItem: true,
        ),
      ],
      totalAmount: 30000,
      paymentMethod: 'cash',
      paidAt: DateTime.utc(2026, 7, 7, 10, 30),
    );

    final text = String.fromCharCodes(bytes);
    expect(text, contains('Pho bo'));
    expect(text, isNot(contains('Service dessert')));
    expect(text, contains('Mon phuc vu: 2'));
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
    final expectedHeader = '${displayFloorLabel(ticket.floorLabel)} / T07';

    expect(floorText, contains(expectedHeader));
    expect(
      floorText.indexOf(expectedHeader),
      lessThan(floorText.indexOf('PHIEU TANG')),
    );
    expect(trayText, contains(expectedHeader));
    expect(
      trayText.indexOf(expectedHeader),
      lessThan(trayText.indexOf('KHAY')),
    );
    expect(floorText, contains('*** MON THEM (DOT 2) ***'));
    expect(floorText, contains('Pho bo'));
    expect(floorText, contains('No onion'));
    expect(trayText, contains('THANG MAY DO AN'));
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
        {
          'label': 'Bún chả',
          'qty': '1',
          'unit_price': '65000',
          'supplemental': 'true',
        },
      ],
    });

    expect(ticket.ticket, 'kitchen');
    expect(ticket.floorLabel, '3F');
    expect(ticket.tableNumber, 'T11');
    expect(ticket.batchNo, 3);
    expect(ticket.items.single.label, 'Bún chả');
    expect(ticket.items.single.quantity, 1);
    expect(ticket.items.single.unitPrice, 65000);
    expect(ticket.items.single.supplemental, isTrue);
  });

  test(
    '2F and 3F order confirmation slips show item prices and total',
    () async {
      for (final floor in const ['2F', '3F']) {
        final ticket = PrintTicket(
          ticket: 'confirmation',
          floorLabel: floor,
          tableNumber: 'T07',
          ticketCode: 'price123',
          batchNo: 1,
          printedReason: 'initial',
          printedAt: '2026-08-08T12:00:00+07:00',
          items: const [
            PrintTicketItem(label: 'Pho bo', quantity: 2, unitPrice: 50000),
            PrintTicketItem(label: 'Tra da', quantity: 1, unitPrice: 5000),
          ],
        );

        final text = String.fromCharCodes(
          await ReceiptBuilder.buildConfirmationSlip(ticket),
        );

        expect(text, contains('${displayFloorLabel(floor)} / T07'));
        expect(text, contains('2 x 50,000 VND = 100,000 VND'));
        expect(text, contains('1 x 5,000 VND = 5,000 VND'));
        expect(text, contains('Tong cong'));
        expect(text, contains('105,000 VND'));
      }
    },
  );

  test(
    '2F and 3F added-order confirmations identify and total all items',
    () async {
      for (final floor in const ['2F', '3F']) {
        final ticket = PrintTicket(
          ticket: 'confirmation',
          floorLabel: floor,
          tableNumber: 'T12',
          ticketCode: 'added123',
          batchNo: 2,
          printedReason: 'added_items',
          printedAt: '2026-08-08T12:10:00+07:00',
          items: const [
            PrintTicketItem(
              label: 'Existing item',
              quantity: 1,
              unitPrice: 50000,
            ),
            PrintTicketItem(
              label: 'Added item',
              quantity: 2,
              unitPrice: 25000,
              supplemental: true,
            ),
          ],
        );

        final text = String.fromCharCodes(
          await ReceiptBuilder.buildConfirmationSlip(ticket),
        );

        expect(text, contains('${displayFloorLabel(floor)} / T12'));
        expect(text, contains('*** MON THEM (DOT 2) ***'));
        expect(text, contains('Existing item'));
        expect(text, contains('+ Added item'));
        expect(text, contains('100,000 VND'));
      }
    },
  );

  test('combo components are preserved and printed for kitchen prep', () async {
    final ticket = PrintTicket.fromPayload({
      'ticket': 'kitchen',
      'floor_label': '1F',
      'table_number': 'T03',
      'ticket_code': 'combo123',
      'batch_no': 1,
      'printed_reason': 'initial',
      'at': '2026-07-27T08:00:00+07:00',
      'items': [
        {
          'label': 'Combo bua trua',
          'qty': 2,
          'components': [
            {'label': 'Com cuon', 'quantity': 1},
            {'label': 'Mi ramen', 'quantity': 2},
            {'label': 'Coca-Cola', 'quantity': 1, 'is_total_quantity': true},
          ],
        },
      ],
    });

    expect(ticket.items.single.components, hasLength(3));
    expect(ticket.items.single.components[1].label, 'Mi ramen');
    expect(ticket.items.single.components[1].quantity, 2);
    expect(
      ticket.items.single.components.last.displayQuantity(
        ticket.items.single.quantity,
      ),
      1,
    );

    final bytes = await ReceiptBuilder.buildKitchenTicket(ticket);
    final text = String.fromCharCodes(bytes);
    expect(text, contains('Combo bua trua'));
    expect(text, contains('Com cuon'));
    expect(text, contains('Mi ramen'));
    expect(text, contains('Coca-Cola'));
    expect(text, contains('x4'));
  });

  test('all fixed printer copy is Vietnamese only', () async {
    const ticket = PrintTicket(
      ticket: 'confirmation',
      floorLabel: '1F',
      tableNumber: 'T01',
      ticketCode: 'vi123',
      batchNo: 1,
      printedReason: 'initial',
      printedAt: '2026-08-07T12:00:00+07:00',
      items: [PrintTicketItem(label: 'Pho bo', quantity: 1)],
    );

    final receipt = String.fromCharCodes(
      await ReceiptBuilder.buildPaymentReceipt(
        restaurantName: 'GLOBOS POS',
        tableNumber: 'T01',
        items: const [
          ReceiptItem(name: 'Pho bo', quantity: 1, unitPrice: 50000),
        ],
        totalAmount: 50000,
        paymentMethod: 'cash',
        paidAt: DateTime.utc(2026, 8, 7, 12),
        receiptNumber: '001',
        cashierCode: 'NV01',
      ),
    );
    final confirmation = String.fromCharCodes(
      await ReceiptBuilder.buildConfirmationSlip(ticket),
    );

    expect(receipt, contains('Phuong thuc : Tien mat'));
    expect(receipt, contains('Cam on quy khach!'));
    expect(
      receipt,
      isNot(
        contains(RegExp(r'Payment|Receipt|Cashier|Subtotal|Discount|Thank')),
      ),
    );
    expect(confirmation, contains('XAC NHAN DON'));
    expect(confirmation, contains('Chi thanh toan tai quay thu ngan'));
    expect(
      confirmation,
      isNot(contains(RegExp(r'ORDER|Payment|Please|receipt'))),
    );
  });
}
