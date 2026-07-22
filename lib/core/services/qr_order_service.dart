import '../../main.dart';

class QrOrderMenu {
  const QrOrderMenu({
    required this.storeName,
    required this.tableNumber,
    required this.floorLabel,
    required this.categories,
    required this.items,
  });

  final String storeName;
  final String tableNumber;
  final String floorLabel;
  final List<QrMenuCategory> categories;
  final List<QrMenuItem> items;

  factory QrOrderMenu.fromJson(Map<String, dynamic> json) {
    final categoriesRaw = json['categories'];
    final itemsRaw = json['items'];
    return QrOrderMenu(
      storeName: json['store_name']?.toString() ?? '',
      tableNumber: json['table_number']?.toString() ?? '-',
      floorLabel: json['floor_label']?.toString() ?? '-',
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
    this.description,
    this.imageUrl,
  });

  final String id;
  final String? categoryId;
  final String name;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final double price;
  final String? description;
  final String? imageUrl;

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
      price: switch (priceRaw) {
        num value => value.toDouble(),
        String value => double.tryParse(value) ?? 0,
        _ => 0,
      },
    );
  }
}

class QrOrderLine {
  const QrOrderLine({required this.menuItemId, required this.quantity});

  final String menuItemId;
  final int quantity;

  Map<String, dynamic> toJson() => {
    'menu_item_id': menuItemId,
    'quantity': quantity,
  };
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
  const QrOrderResultItem({required this.name, required this.quantity});

  final String name;
  final int quantity;

  factory QrOrderResultItem.fromJson(Map<String, dynamic> json) {
    return QrOrderResultItem(
      name: json['name']?.toString() ?? '',
      quantity: switch (json['quantity']) {
        int value => value,
        num value => value.toInt(),
        String value => int.tryParse(value) ?? 1,
        _ => 1,
      },
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
      },
    );
    return QrOrderResult.fromJson(Map<String, dynamic>.from(result as Map));
  }
}

final qrOrderService = QrOrderService();
