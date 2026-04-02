class CartItem {
  const CartItem({
    required this.menuItemId,
    required this.name,
    required this.price,
    required this.quantity,
  });

  final String menuItemId;
  final String name;
  final double price;
  final int quantity;

  CartItem copyWith({
    String? menuItemId,
    String? name,
    double? price,
    int? quantity,
  }) {
    return CartItem(
      menuItemId: menuItemId ?? this.menuItemId,
      name: name ?? this.name,
      price: price ?? this.price,
      quantity: quantity ?? this.quantity,
    );
  }
}

class OrderItem {
  const OrderItem({
    required this.id,
    required this.menuItemId,
    required this.label,
    required this.unitPrice,
    required this.quantity,
    required this.status,
    required this.itemType,
  });

  final String id;
  final String? menuItemId;
  final String? label;
  final double unitPrice;
  final int quantity;
  final String status;
  final String itemType;

  factory OrderItem.fromJson(Map<String, dynamic> json) {
    final unitPriceRaw = json['unit_price'];
    final quantityRaw = json['quantity'];

    return OrderItem(
      id: json['id'].toString(),
      menuItemId: json['menu_item_id']?.toString(),
      label: json['label']?.toString(),
      unitPrice: switch (unitPriceRaw) {
        num value => value.toDouble(),
        String value => double.tryParse(value) ?? 0,
        _ => 0,
      },
      quantity: switch (quantityRaw) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 0,
        _ => 0,
      },
      status: json['status']?.toString() ?? 'pending',
      itemType: json['item_type']?.toString() ?? 'menu',
    );
  }
}

class Order {
  const Order({
    required this.id,
    required this.tableId,
    required this.status,
    required this.createdAt,
    required this.items,
  });

  final String id;
  final String tableId;
  final String status;
  final DateTime createdAt;
  final List<OrderItem> items;

  factory Order.fromJson(Map<String, dynamic> json) {
    final createdAtRaw = json['created_at']?.toString();
    final rawItems = json['order_items'];
    final items = (rawItems is List)
        ? rawItems
            .map<OrderItem>(
              (item) => OrderItem.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList()
        : const <OrderItem>[];

    return Order(
      id: json['id'].toString(),
      tableId: json['table_id'].toString(),
      status: json['status']?.toString() ?? 'pending',
      createdAt: createdAtRaw != null
          ? DateTime.tryParse(createdAtRaw) ?? DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.fromMillisecondsSinceEpoch(0),
      items: items,
    );
  }
}
