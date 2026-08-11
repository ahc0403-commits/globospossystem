class DigitalReceiptItem {
  const DigitalReceiptItem({
    required this.label,
    required this.quantity,
    required this.unitPrice,
    required this.lineTotal,
    required this.isServiceItem,
  });

  final String label;
  final int quantity;
  final double unitPrice;
  final double lineTotal;
  final bool isServiceItem;

  factory DigitalReceiptItem.fromJson(Map<String, dynamic> json) =>
      DigitalReceiptItem(
        label: json['label']?.toString() ?? 'Item',
        quantity: _asInt(json['quantity']),
        unitPrice: _asDouble(json['unit_price']),
        lineTotal: _asDouble(json['line_total']),
        isServiceItem: json['is_service_item'] == true,
      );
}

class DigitalReceiptPayment {
  const DigitalReceiptPayment({required this.method, required this.amount});

  final String method;
  final double amount;

  factory DigitalReceiptPayment.fromJson(Map<String, dynamic> json) =>
      DigitalReceiptPayment(
        method: json['method']?.toString() ?? 'OTHER',
        amount: _asDouble(json['amount']),
      );
}

class DigitalReceipt {
  const DigitalReceipt({
    required this.id,
    required this.orderId,
    required this.receiptNumber,
    required this.restaurantName,
    required this.addressLines,
    required this.tableNumber,
    required this.cashierCode,
    required this.paidAt,
    required this.items,
    required this.payments,
    required this.subtotalAmount,
    required this.serviceChargeAmount,
    required this.discountAmount,
    required this.vatAmount,
    required this.totalAmount,
    required this.receivedAmount,
    required this.changeAmount,
    required this.paymentMethod,
    required this.isService,
    this.legalName,
    this.taxCode,
  });

  final String id;
  final String orderId;
  final String receiptNumber;
  final String restaurantName;
  final String? legalName;
  final String? taxCode;
  final List<String> addressLines;
  final String tableNumber;
  final String cashierCode;
  final DateTime paidAt;
  final List<DigitalReceiptItem> items;
  final List<DigitalReceiptPayment> payments;
  final double subtotalAmount;
  final double serviceChargeAmount;
  final double discountAmount;
  final double vatAmount;
  final double totalAmount;
  final double receivedAmount;
  final double changeAmount;
  final String paymentMethod;
  final bool isService;

  factory DigitalReceipt.fromJson(Map<String, dynamic> json) {
    final rawItems = json['items'];
    final rawPayments = json['payments'];
    final rawAddresses = json['address_lines'];
    return DigitalReceipt(
      id: json['receipt_id']?.toString() ?? '',
      orderId: json['order_id']?.toString() ?? '',
      receiptNumber: json['receipt_number']?.toString() ?? '-',
      restaurantName: json['restaurant_name']?.toString() ?? '-',
      legalName: _optionalText(json['legal_name']),
      taxCode: _optionalText(json['tax_code']),
      addressLines: rawAddresses is List
          ? rawAddresses
                .map((line) => line?.toString().trim() ?? '')
                .where((line) => line.isNotEmpty)
                .toList(growable: false)
          : const [],
      tableNumber: json['table_number']?.toString() ?? '-',
      cashierCode: json['cashier_code']?.toString() ?? 'CASHIER',
      paidAt:
          DateTime.tryParse(json['paid_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) => DigitalReceiptItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
      payments: rawPayments is List
          ? rawPayments
                .whereType<Map>()
                .map(
                  (payment) => DigitalReceiptPayment.fromJson(
                    Map<String, dynamic>.from(payment),
                  ),
                )
                .toList(growable: false)
          : const [],
      subtotalAmount: _asDouble(json['subtotal_amount']),
      serviceChargeAmount: _asDouble(json['service_charge_amount']),
      discountAmount: _asDouble(json['discount_amount']),
      vatAmount: _asDouble(json['vat_amount']),
      totalAmount: _asDouble(json['total_amount']),
      receivedAmount: _asDouble(json['received_amount']),
      changeAmount: _asDouble(json['change_amount']),
      paymentMethod: json['payment_method']?.toString() ?? 'OTHER',
      isService: json['is_service'] == true,
    );
  }
}

class DigitalReceiptAccess {
  const DigitalReceiptAccess({
    required this.receiptId,
    required this.receiptNumber,
    required this.token,
    required this.publicUrl,
    this.snapshot,
  });

  final String receiptId;
  final String receiptNumber;
  final String token;
  final String publicUrl;
  final DigitalReceipt? snapshot;
}

double _asDouble(Object? value) => switch (value) {
  num number => number.toDouble(),
  String text => double.tryParse(text) ?? 0,
  _ => 0,
};

int _asInt(Object? value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};

String? _optionalText(Object? value) {
  final text = value?.toString().trim() ?? '';
  return text.isEmpty ? null : text;
}
