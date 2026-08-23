import '../../main.dart';

class QrOrderMenu {
  const QrOrderMenu({
    this.storeId,
    required this.storeName,
    required this.tableNumber,
    required this.floorLabel,
    required this.categories,
    required this.items,
    this.promotionName,
    this.promotionDiscountPercent = 0,
  });

  final String? storeId;
  final String storeName;
  final String tableNumber;
  final String floorLabel;
  final List<QrMenuCategory> categories;
  final List<QrMenuItem> items;
  final String? promotionName;
  final double promotionDiscountPercent;

  factory QrOrderMenu.fromJson(Map<String, dynamic> json) {
    final categoriesRaw = json['categories'];
    final itemsRaw = json['items'];
    return QrOrderMenu(
      storeId: json['store_id']?.toString(),
      storeName: json['store_name']?.toString() ?? '',
      tableNumber: json['table_number']?.toString() ?? '-',
      floorLabel: json['floor_label']?.toString() ?? '-',
      promotionName: json['promotion_name']?.toString(),
      promotionDiscountPercent: _jsonDouble(json['promotion_discount_percent']),
      categories: categoriesRaw is List
          ? categoriesRaw
                .whereType<Map>()
                .map(
                  (item) =>
                      QrMenuCategory.fromJson(Map<String, dynamic>.from(item)),
                )
                .toList()
          : const <QrMenuCategory>[],
      items: itemsRaw is List
          ? itemsRaw
                .whereType<Map>()
                .map(
                  (item) =>
                      QrMenuItem.fromJson(Map<String, dynamic>.from(item)),
                )
                .toList()
          : const <QrMenuItem>[],
    );
  }
}

class QrMenuCategory {
  const QrMenuCategory({
    required this.id,
    required this.name,
    this.nameKo = '',
    this.nameVi = '',
    this.nameEn = '',
  });

  final String id;
  final String name;
  final String nameKo;
  final String nameVi;
  final String nameEn;

  String localizedName(String languageCode) => switch (languageCode) {
    'ko' => nameKo.isEmpty ? name : nameKo,
    'vi' => nameVi.isEmpty ? name : nameVi,
    _ => nameEn.isEmpty ? name : nameEn,
  };

  factory QrMenuCategory.fromJson(Map<String, dynamic> json) {
    final fallback = json['name']?.toString() ?? '';
    return QrMenuCategory(
      id: json['id']?.toString() ?? '',
      name: fallback,
      nameKo: json['name_ko']?.toString() ?? fallback,
      nameVi: json['name_vi']?.toString() ?? fallback,
      nameEn: json['name_en']?.toString() ?? fallback,
    );
  }
}

class QrMenuItem {
  const QrMenuItem({
    required this.id,
    required this.categoryId,
    required this.name,
    this.nameKo = '',
    this.nameVi = '',
    this.nameEn = '',
    required this.price,
    this.originalPrice,
    this.discountPercent = 0,
    this.description,
    this.imageUrl,
    this.isCombo = false,
    this.comboDrinkChoiceCount = 0,
    this.comboDrinkOptions = const [],
  });

  final String id;
  final String? categoryId;
  final String name;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final double price;
  final double? originalPrice;
  final double discountPercent;
  final String? description;
  final String? imageUrl;
  final bool isCombo;
  final int comboDrinkChoiceCount;
  final List<QrComboDrinkOption> comboDrinkOptions;

  String localizedName(String languageCode) => switch (languageCode) {
    'ko' => nameKo.isEmpty ? name : nameKo,
    'vi' => nameVi.isEmpty ? name : nameVi,
    _ => nameEn.isEmpty ? name : nameEn,
  };

  factory QrMenuItem.fromJson(Map<String, dynamic> json) {
    final priceRaw = json['price'];
    final fallback = json['name']?.toString() ?? '';
    return QrMenuItem(
      id: json['id']?.toString() ?? '',
      categoryId: json['category_id']?.toString(),
      name: fallback,
      nameKo: json['name_ko']?.toString() ?? fallback,
      nameVi: json['name_vi']?.toString() ?? fallback,
      nameEn: json['name_en']?.toString() ?? fallback,
      description: json['description']?.toString(),
      imageUrl: json['image_url']?.toString(),
      price: _jsonDouble(priceRaw),
      originalPrice: json['original_price'] == null
          ? null
          : _jsonDouble(json['original_price']),
      discountPercent: _jsonDouble(json['discount_percent']),
      isCombo: json['is_combo'] == true,
      comboDrinkChoiceCount: _jsonInt(json['combo_drink_choice_count']),
      comboDrinkOptions: json['combo_drink_options'] is List
          ? (json['combo_drink_options'] as List)
                .whereType<Map>()
                .map(
                  (option) => QrComboDrinkOption.fromJson(
                    Map<String, dynamic>.from(option),
                  ),
                )
                .toList(growable: false)
          : const [],
    );
  }
}

class QrComboDrinkOption {
  const QrComboDrinkOption({
    required this.id,
    required this.name,
    this.nameKo = '',
    this.nameVi = '',
    this.nameEn = '',
  });

  final String id;
  final String name;
  final String nameKo;
  final String nameVi;
  final String nameEn;

  String localizedName(String languageCode) => switch (languageCode) {
    'ko' => nameKo.isEmpty ? name : nameKo,
    'vi' => nameVi.isEmpty ? name : nameVi,
    _ => nameEn.isEmpty ? name : nameEn,
  };

  factory QrComboDrinkOption.fromJson(Map<String, dynamic> json) {
    final fallback = json['name']?.toString() ?? '';
    return QrComboDrinkOption(
      id: json['id']?.toString() ?? '',
      name: fallback,
      nameKo: json['name_ko']?.toString() ?? fallback,
      nameVi: json['name_vi']?.toString() ?? fallback,
      nameEn: json['name_en']?.toString() ?? fallback,
    );
  }
}

double _jsonDouble(dynamic value) => switch (value) {
  num number => number.toDouble(),
  String text => double.tryParse(text) ?? 0,
  _ => 0,
};

int _jsonInt(dynamic value) => switch (value) {
  int number => number,
  num number => number.toInt(),
  String text => int.tryParse(text) ?? 0,
  _ => 0,
};

class QrOrderLine {
  const QrOrderLine({
    required this.menuItemId,
    required this.quantity,
    this.isTakeout = false,
    this.comboDrinkChoices = const [],
  });

  final String menuItemId;
  final int quantity;
  final bool isTakeout;
  final List<String> comboDrinkChoices;

  Map<String, dynamic> toJson() => {
    'menu_item_id': menuItemId,
    'quantity': quantity,
    if (isTakeout) 'is_takeout': true,
    if (comboDrinkChoices.isNotEmpty) 'combo_drink_choices': comboDrinkChoices,
  };
}

class QrActiveOrder {
  const QrActiveOrder({
    required this.isActive,
    required this.orderCode,
    required this.status,
    this.fulfillmentMode = 'pos_print',
    required this.items,
    this.leftoverPackagingStatus,
  });

  final bool isActive;
  final String orderCode;
  final String status;
  final String fulfillmentMode;
  final List<QrActiveOrderItem> items;
  final String? leftoverPackagingStatus;

  bool get isPaperless => fulfillmentMode == 'paperless';

  factory QrActiveOrder.fromJson(Map<String, dynamic> json) {
    final itemsRaw = json['items'];
    return QrActiveOrder(
      isActive: json['active'] == true,
      orderCode: json['order_code']?.toString() ?? '',
      status: json['status']?.toString() ?? 'pending',
      fulfillmentMode: json['fulfillment_mode']?.toString() ?? 'pos_print',
      leftoverPackagingStatus: json['leftover_packaging_status']?.toString(),
      items: itemsRaw is List
          ? itemsRaw
                .whereType<Map>()
                .map(
                  (item) => QrActiveOrderItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList(growable: false)
          : const <QrActiveOrderItem>[],
    );
  }
}

class QrActiveOrderItem {
  const QrActiveOrderItem({
    required this.name,
    this.nameKo = '',
    this.nameVi = '',
    this.nameEn = '',
    required this.quantity,
    required this.status,
    this.servedQuantity = 0,
    this.fulfillmentParts = const [],
    this.isTakeout = false,
  });

  final String name;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final int quantity;
  final String status;
  final int servedQuantity;
  final List<QrFulfillmentPart> fulfillmentParts;
  final bool isTakeout;

  int get remainingQuantity => (quantity - servedQuantity).clamp(0, quantity);

  String localizedName(String languageCode) => switch (languageCode) {
    'ko' => nameKo.isEmpty ? name : nameKo,
    'vi' => nameVi.isEmpty ? name : nameVi,
    _ => nameEn.isEmpty ? name : nameEn,
  };

  factory QrActiveOrderItem.fromJson(Map<String, dynamic> json) {
    final fallback = json['name']?.toString() ?? '';
    return QrActiveOrderItem(
      name: fallback,
      nameKo: json['name_ko']?.toString() ?? fallback,
      nameVi: json['name_vi']?.toString() ?? fallback,
      nameEn: json['name_en']?.toString() ?? fallback,
      quantity: _jsonInt(json['quantity']),
      status: json['status']?.toString() ?? 'pending',
      servedQuantity: _jsonInt(json['served_quantity']),
      isTakeout: json['is_takeout'] == true,
      fulfillmentParts: switch (json['fulfillment_parts']) {
        final List values =>
          values
              .whereType<Map>()
              .map(
                (part) =>
                    QrFulfillmentPart.fromJson(Map<String, dynamic>.from(part)),
              )
              .toList(growable: false),
        _ => const <QrFulfillmentPart>[],
      },
    );
  }
}

class QrFulfillmentPart {
  const QrFulfillmentPart({
    required this.lineKey,
    required this.name,
    this.nameKo = '',
    this.nameVi = '',
    this.nameEn = '',
    required this.quantity,
    required this.servedQuantity,
    required this.fulfillmentRoute,
  });

  final String lineKey;
  final String name;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final int quantity;
  final int servedQuantity;
  final String fulfillmentRoute;

  int get remainingQuantity => (quantity - servedQuantity).clamp(0, quantity);

  String localizedName(String languageCode) => switch (languageCode) {
    'ko' => nameKo.isEmpty ? name : nameKo,
    'vi' => nameVi.isEmpty ? name : nameVi,
    _ => nameEn.isEmpty ? name : nameEn,
  };

  factory QrFulfillmentPart.fromJson(Map<String, dynamic> json) {
    final fallback = json['name']?.toString() ?? '';
    return QrFulfillmentPart(
      lineKey: json['line_key']?.toString() ?? 'base',
      name: fallback,
      nameKo: json['name_ko']?.toString() ?? fallback,
      nameVi: json['name_vi']?.toString() ?? fallback,
      nameEn: json['name_en']?.toString() ?? fallback,
      quantity: _jsonInt(json['quantity']),
      servedQuantity: _jsonInt(json['served_quantity']),
      fulfillmentRoute:
          json['fulfillment_route']?.toString() ?? 'kitchen_tray_floor',
    );
  }
}

class QrOrderResult {
  const QrOrderResult({
    required this.orderCode,
    required this.batchNo,
    required this.tableNumber,
    required this.floorLabel,
    required this.items,
  });

  final String orderCode;
  final int batchNo;
  final String tableNumber;
  final String floorLabel;
  final List<QrOrderResultItem> items;

  factory QrOrderResult.fromJson(Map<String, dynamic> json) {
    final itemsRaw = json['items'];
    return QrOrderResult(
      orderCode: json['order_code']?.toString() ?? '',
      batchNo: switch (json['batch_no']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 1,
        _ => 1,
      },
      tableNumber: json['table_number']?.toString() ?? '-',
      floorLabel: json['floor_label']?.toString() ?? '-',
      items: itemsRaw is List
          ? itemsRaw
                .whereType<Map>()
                .map(
                  (item) => QrOrderResultItem.fromJson(
                    Map<String, dynamic>.from(item),
                  ),
                )
                .toList()
          : const <QrOrderResultItem>[],
    );
  }
}

class QrOrderResultItem {
  const QrOrderResultItem({
    required this.name,
    required this.quantity,
    this.isTakeout = false,
  });

  final String name;
  final int quantity;
  final bool isTakeout;

  factory QrOrderResultItem.fromJson(Map<String, dynamic> json) {
    return QrOrderResultItem(
      name: json['name']?.toString() ?? '',
      quantity: switch (json['quantity']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 1,
        _ => 1,
      },
      isTakeout: json['is_takeout'] == true,
    );
  }
}

class QrOrderService {
  Future<QrOrderMenu> fetchMenu(String token) async {
    final result = await supabase.rpc(
      'qr_get_menu',
      params: {'p_token': token},
    );
    return QrOrderMenu.fromJson(Map<String, dynamic>.from(result as Map));
  }

  Future<QrActiveOrder> fetchActiveOrder(String token) async {
    final result = await supabase.rpc(
      'qr_get_active_order',
      params: {'p_token': token},
    );
    return QrActiveOrder.fromJson(Map<String, dynamic>.from(result as Map));
  }

  Future<QrOrderResult> placeOrder({
    required String token,
    required List<QrOrderLine> items,
    required String clientOrderId,
  }) async {
    final result = await supabase.rpc(
      'qr_place_order',
      params: {
        'p_token': token,
        'p_items': items.map((item) => item.toJson()).toList(),
        'p_client_order_id': clientOrderId,
        'p_validate_combo_choices': true,
      },
    );
    return QrOrderResult.fromJson(Map<String, dynamic>.from(result as Map));
  }

  Future<Map<String, dynamic>> requestLeftoverPackaging({
    required String token,
    required String requestId,
  }) async {
    final result = await supabase.rpc(
      'qr_request_leftover_packaging',
      params: {'p_token': token, 'p_request_id': requestId},
    );
    return Map<String, dynamic>.from(result as Map);
  }
}

final qrOrderService = QrOrderService();
