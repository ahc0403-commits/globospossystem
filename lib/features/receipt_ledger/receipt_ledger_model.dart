class ReceiptLedgerSummary {
  const ReceiptLedgerSummary({
    required this.receiptCount,
    required this.grossAmount,
    required this.adjustedAmount,
    required this.netAmount,
  });

  factory ReceiptLedgerSummary.fromJson(Map<String, dynamic> json) =>
      ReceiptLedgerSummary(
        receiptCount: _int(json['receipt_count']),
        grossAmount: _double(json['gross_amount']),
        adjustedAmount: _double(json['adjusted_amount']),
        netAmount: _double(json['net_amount']),
      );

  final int receiptCount;
  final double grossAmount;
  final double adjustedAmount;
  final double netAmount;
}

class ReceiptLedgerPayment {
  const ReceiptLedgerPayment({required this.method, required this.amount});

  factory ReceiptLedgerPayment.fromJson(Map<String, dynamic> json) =>
      ReceiptLedgerPayment(
        method: json['method']?.toString() ?? 'OTHER',
        amount: _double(json['amount']),
      );

  final String method;
  final double amount;
}

class ReceiptLedgerItem {
  const ReceiptLedgerItem({
    required this.name,
    required this.quantity,
    required this.unitPrice,
    this.orderId,
    this.tableNumber,
  });

  factory ReceiptLedgerItem.fromJson(Map<String, dynamic> json) =>
      ReceiptLedgerItem(
        name: json['name']?.toString() ?? 'Item',
        quantity: _int(json['quantity']),
        unitPrice: _double(json['unit_price']),
        orderId: json['order_id']?.toString(),
        tableNumber: json['table_number']?.toString(),
      );

  final String name;
  final int quantity;
  final double unitPrice;
  final String? orderId;
  final String? tableNumber;

  double get lineTotal => unitPrice * quantity;
}

class ReceiptLedgerAllocation {
  const ReceiptLedgerAllocation({
    required this.orderId,
    required this.tableNumber,
    required this.amount,
  });

  factory ReceiptLedgerAllocation.fromJson(Map<String, dynamic> json) =>
      ReceiptLedgerAllocation(
        orderId: json['order_id']?.toString() ?? '',
        tableNumber: json['table_number']?.toString() ?? '-',
        amount: _double(json['amount']),
      );

  final String orderId;
  final String tableNumber;
  final double amount;
}

class ReceiptLedgerEntry {
  const ReceiptLedgerEntry({
    required this.receiptId,
    required this.receiptNumber,
    required this.orderId,
    required this.combinedPaymentGroupId,
    required this.orderIds,
    required this.storeId,
    required this.storeName,
    required this.soldAt,
    required this.tableNumber,
    required this.salesChannel,
    required this.cashierName,
    required this.payments,
    required this.allocations,
    required this.items,
    required this.grossAmount,
    required this.adjustedAmount,
    required this.netAmount,
    required this.status,
    required this.source,
    required this.scope,
    required this.printable,
    required this.digitalReceiptReady,
    required this.receivedAmount,
  });

  factory ReceiptLedgerEntry.fromJson(Map<String, dynamic> json) {
    final rawPayments = json['payments'];
    final rawAllocations = json['allocations'];
    final rawItems = json['items'];
    final rawOrderIds = json['order_ids'];
    return ReceiptLedgerEntry(
      receiptId: json['receipt_id']?.toString() ?? '',
      receiptNumber: json['receipt_number']?.toString() ?? '-',
      orderId: json['order_id']?.toString(),
      combinedPaymentGroupId: json['combined_payment_group_id']?.toString(),
      orderIds: rawOrderIds is List
          ? rawOrderIds
                .map((orderId) => orderId.toString())
                .toList(growable: false)
          : const [],
      storeId: json['store_id']?.toString() ?? '',
      storeName: json['store_name']?.toString() ?? '-',
      soldAt: DateTime.parse(json['sold_at'].toString()),
      tableNumber: json['table_number']?.toString() ?? '-',
      salesChannel: json['sales_channel']?.toString() ?? '-',
      cashierName: json['cashier_name']?.toString() ?? '-',
      payments: rawPayments is List
          ? rawPayments
                .whereType<Map>()
                .map(
                  (payment) => ReceiptLedgerPayment.fromJson(
                    Map<String, dynamic>.from(payment),
                  ),
                )
                .toList(growable: false)
          : const [],
      allocations: rawAllocations is List
          ? rawAllocations
                .whereType<Map>()
                .map(
                  (allocation) => ReceiptLedgerAllocation.fromJson(
                    Map<String, dynamic>.from(allocation),
                  ),
                )
                .toList(growable: false)
          : const [],
      items: rawItems is List
          ? rawItems
                .whereType<Map>()
                .map(
                  (item) => ReceiptLedgerItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const [],
      grossAmount: _double(json['gross_amount']),
      adjustedAmount: _double(json['adjusted_amount']),
      netAmount: _double(json['net_amount']),
      status: json['receipt_status']?.toString() ?? 'paid',
      source: json['receipt_source']?.toString() ?? 'pos',
      scope: json['receipt_scope']?.toString() ?? 'single',
      printable: json['printable'] == true,
      digitalReceiptReady: json['digital_receipt_ready'] == true,
      receivedAmount: _double(json['received_amount']),
    );
  }

  final String receiptId;
  final String receiptNumber;
  final String? orderId;
  final String? combinedPaymentGroupId;
  final List<String> orderIds;
  final String storeId;
  final String storeName;
  final DateTime soldAt;
  final String tableNumber;
  final String salesChannel;
  final String cashierName;
  final List<ReceiptLedgerPayment> payments;
  final List<ReceiptLedgerAllocation> allocations;
  final List<ReceiptLedgerItem> items;
  final double grossAmount;
  final double adjustedAmount;
  final double netAmount;
  final String status;
  final String source;
  final String scope;
  final bool printable;
  final bool digitalReceiptReady;
  final double receivedAmount;

  bool get isCombined => combinedPaymentGroupId != null || scope == 'combined';
}

class ReceiptLedgerPage {
  const ReceiptLedgerPage({
    required this.businessDate,
    required this.generatedAt,
    required this.summary,
    required this.receipts,
    required this.hasMore,
  });

  factory ReceiptLedgerPage.fromJson(Map<String, dynamic> json) {
    final rawSummary = json['summary'];
    final rawReceipts = json['receipts'];
    return ReceiptLedgerPage(
      businessDate: json['business_date']?.toString() ?? '',
      generatedAt: DateTime.parse(json['generated_at'].toString()),
      summary: ReceiptLedgerSummary.fromJson(
        rawSummary is Map
            ? Map<String, dynamic>.from(rawSummary)
            : const <String, dynamic>{},
      ),
      receipts: rawReceipts is List
          ? rawReceipts
                .whereType<Map>()
                .map(
                  (receipt) => ReceiptLedgerEntry.fromJson(
                    Map<String, dynamic>.from(receipt),
                  ),
                )
                .toList(growable: false)
          : const [],
      hasMore: json['has_more'] == true,
    );
  }

  final String businessDate;
  final DateTime generatedAt;
  final ReceiptLedgerSummary summary;
  final List<ReceiptLedgerEntry> receipts;
  final bool hasMore;
}

double _double(Object? value) => switch (value) {
  num number => number.toDouble(),
  String text => double.tryParse(text) ?? 0,
  _ => 0,
};

int _int(Object? value) => switch (value) {
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};
