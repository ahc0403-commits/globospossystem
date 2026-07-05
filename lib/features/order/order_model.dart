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
    this.vatCategory,
    this.payingAmountIncTax,
  });

  final String id;
  final String? menuItemId;
  final String? label;
  final double unitPrice;
  final int quantity;
  final String status;
  final String itemType;
  final String? vatCategory;
  final double? payingAmountIncTax;

  OrderItem copyWith({
    String? id,
    String? menuItemId,
    String? label,
    double? unitPrice,
    int? quantity,
    String? status,
    String? itemType,
    String? vatCategory,
    double? payingAmountIncTax,
  }) {
    return OrderItem(
      id: id ?? this.id,
      menuItemId: menuItemId ?? this.menuItemId,
      label: label ?? this.label,
      unitPrice: unitPrice ?? this.unitPrice,
      quantity: quantity ?? this.quantity,
      status: status ?? this.status,
      itemType: itemType ?? this.itemType,
      vatCategory: vatCategory ?? this.vatCategory,
      payingAmountIncTax: payingAmountIncTax ?? this.payingAmountIncTax,
    );
  }

  factory OrderItem.fromJson(Map<String, dynamic> json) {
    final unitPriceRaw = json['unit_price'];
    final quantityRaw = json['quantity'];
    final payingAmountRaw = json['paying_amount_inc_tax'];
    final menuItemRaw = json['menu_items'];
    String? menuItemName;
    String? vatCategory;
    if (menuItemRaw is Map) {
      menuItemName = menuItemRaw['name']?.toString();
      vatCategory = menuItemRaw['vat_category']?.toString();
    }

    return OrderItem(
      id: json['id'].toString(),
      menuItemId: json['menu_item_id']?.toString(),
      label:
          json['label']?.toString() ?? json['name']?.toString() ?? menuItemName,
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
      itemType: json['item_type']?.toString() ?? 'menu_item',
      vatCategory: json['vat_category']?.toString() ?? vatCategory,
      payingAmountIncTax: switch (payingAmountRaw) {
        num value => value.toDouble(),
        String value => double.tryParse(value),
        _ => null,
      },
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
    this.guestCount,
  });

  final String id;
  final String tableId;
  final String status;
  final DateTime createdAt;
  final List<OrderItem> items;
  final int? guestCount;

  Order copyWith({
    String? id,
    String? tableId,
    String? status,
    DateTime? createdAt,
    List<OrderItem>? items,
    int? guestCount,
  }) {
    return Order(
      id: id ?? this.id,
      tableId: tableId ?? this.tableId,
      status: status ?? this.status,
      createdAt: createdAt ?? this.createdAt,
      items: items ?? this.items,
      guestCount: guestCount ?? this.guestCount,
    );
  }

  factory Order.fromJson(Map<String, dynamic> json) {
    final createdAtRaw = json['created_at']?.toString();
    final rawItems = json['order_items'];
    final itemRows = rawItems is List
        ? rawItems
              .map((item) => Map<String, dynamic>.from(item as Map))
              .toList()
        : <Map<String, dynamic>>[];
    itemRows.sort(_compareOrderItemRowsByCreatedAt);
    final items = itemRows.map<OrderItem>(OrderItem.fromJson).toList();

    return Order(
      id: json['id'].toString(),
      tableId: json['table_id'].toString(),
      status: json['status']?.toString() ?? 'pending',
      createdAt: createdAtRaw != null
          ? DateTime.tryParse(createdAtRaw) ??
                DateTime.fromMillisecondsSinceEpoch(0)
          : DateTime.fromMillisecondsSinceEpoch(0),
      items: items,
      guestCount: switch (json['guest_count']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value),
        _ => null,
      },
    );
  }
}

int _compareOrderItemRowsByCreatedAt(
  Map<String, dynamic> left,
  Map<String, dynamic> right,
) {
  final leftCreatedAt = DateTime.tryParse(left['created_at']?.toString() ?? '');
  final rightCreatedAt = DateTime.tryParse(
    right['created_at']?.toString() ?? '',
  );

  if (leftCreatedAt != null && rightCreatedAt != null) {
    final createdAtComparison = leftCreatedAt.compareTo(rightCreatedAt);
    if (createdAtComparison != 0) {
      return createdAtComparison;
    }
  } else if (leftCreatedAt != null) {
    return -1;
  } else if (rightCreatedAt != null) {
    return 1;
  }

  return (left['id']?.toString() ?? '').compareTo(
    right['id']?.toString() ?? '',
  );
}
