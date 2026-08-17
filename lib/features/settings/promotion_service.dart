import '../../main.dart';

const String promotionScopeAllMenu = 'all_menu';
const String promotionScopeSelectedItems = 'selected_items';

class StorePromotion {
  const StorePromotion({
    required this.id,
    required this.name,
    required this.discountPercent,
    required this.startsAt,
    required this.endsAt,
    required this.isActive,
    required this.scope,
    this.menuItemIds = const [],
  });

  factory StorePromotion.fromJson(Map<String, dynamic> json) {
    final targetsRaw = json['store_promotion_menu_items'];
    final menuItemIds = targetsRaw is List
        ? targetsRaw
              .whereType<Map>()
              .map((target) => target['menu_item_id']?.toString() ?? '')
              .where((id) => id.isNotEmpty)
              .toList(growable: false)
        : const <String>[];
    return StorePromotion(
      id: json['id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      discountPercent: (json['discount_percent'] as num?)?.toDouble() ?? 0,
      startsAt: DateTime.parse(json['starts_at'].toString()).toLocal(),
      endsAt: DateTime.parse(json['ends_at'].toString()).toLocal(),
      isActive: json['is_active'] == true,
      scope: json['scope']?.toString() ?? promotionScopeAllMenu,
      menuItemIds: menuItemIds,
    );
  }

  final String id;
  final String name;
  final double discountPercent;
  final DateTime startsAt;
  final DateTime endsAt;
  final bool isActive;
  final String scope;
  final List<String> menuItemIds;

  bool get targetsAllMenus => scope == promotionScopeAllMenu;
}

class PromotionMenuItem {
  const PromotionMenuItem({
    required this.id,
    required this.name,
    required this.nameKo,
    required this.nameVi,
    required this.nameEn,
    required this.price,
    required this.isAvailable,
  });

  factory PromotionMenuItem.fromJson(Map<String, dynamic> json) {
    final fallback = json['name']?.toString() ?? '';
    return PromotionMenuItem(
      id: json['id']?.toString() ?? '',
      name: fallback,
      nameKo: json['name_ko']?.toString() ?? fallback,
      nameVi: json['name_vi']?.toString() ?? fallback,
      nameEn: json['name_en']?.toString() ?? fallback,
      price: (json['price'] as num?)?.toDouble() ?? 0,
      isAvailable: json['is_available'] == true,
    );
  }

  final String id;
  final String name;
  final String nameKo;
  final String nameVi;
  final String nameEn;
  final double price;
  final bool isAvailable;

  String localizedName(String languageCode) => switch (languageCode) {
    'ko' => nameKo.isEmpty ? name : nameKo,
    'vi' => nameVi.isEmpty ? name : nameVi,
    _ => nameEn.isEmpty ? name : nameEn,
  };
}

class PromotionService {
  Future<List<StorePromotion>> list(String storeId) async {
    final rows = await supabase
        .from('store_promotions')
        .select(
          'id, name, discount_percent, starts_at, ends_at, is_active, scope, '
          'store_promotion_menu_items(menu_item_id)',
        )
        .eq('restaurant_id', storeId)
        .order('starts_at', ascending: false);
    return rows
        .map((row) => StorePromotion.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<List<PromotionMenuItem>> listMenuItems(String storeId) async {
    final rows = await supabase
        .from('menu_items')
        .select('id, name, name_ko, name_vi, name_en, price, is_available')
        .eq('restaurant_id', storeId)
        .eq('is_archived', false)
        .order('sort_order', ascending: true);
    return rows
        .map(
          (row) => PromotionMenuItem.fromJson(Map<String, dynamic>.from(row)),
        )
        .toList(growable: false);
  }

  Future<void> save({
    required String storeId,
    String? id,
    required String name,
    required double discountPercent,
    required DateTime startsAt,
    required DateTime endsAt,
    required bool isActive,
    required String scope,
    required List<String> menuItemIds,
  }) async {
    await supabase.rpc(
      'upsert_store_promotion_v2',
      params: {
        'p_store_id': storeId,
        'p_promotion_id': id,
        'p_name': name,
        'p_discount_percent': discountPercent,
        'p_starts_at': startsAt.toUtc().toIso8601String(),
        'p_ends_at': endsAt.toUtc().toIso8601String(),
        'p_scope': scope,
        'p_menu_item_ids': menuItemIds,
        'p_is_active': isActive,
      },
    );
  }
}

final promotionService = PromotionService();
