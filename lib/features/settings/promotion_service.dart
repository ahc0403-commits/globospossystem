import '../../main.dart';

class StorePromotion {
  const StorePromotion({
    required this.id,
    required this.name,
    required this.discountPercent,
    required this.startsAt,
    required this.endsAt,
    required this.isActive,
  });

  factory StorePromotion.fromJson(Map<String, dynamic> json) => StorePromotion(
    id: json['id']?.toString() ?? '',
    name: json['name']?.toString() ?? '',
    discountPercent: (json['discount_percent'] as num?)?.toDouble() ?? 0,
    startsAt: DateTime.parse(json['starts_at'].toString()).toLocal(),
    endsAt: DateTime.parse(json['ends_at'].toString()).toLocal(),
    isActive: json['is_active'] == true,
  );

  final String id;
  final String name;
  final double discountPercent;
  final DateTime startsAt;
  final DateTime endsAt;
  final bool isActive;
}

class PromotionService {
  Future<List<StorePromotion>> list(String storeId) async {
    final rows = await supabase
        .from('store_promotions')
        .select('id, name, discount_percent, starts_at, ends_at, is_active')
        .eq('restaurant_id', storeId)
        .order('starts_at', ascending: false);
    return rows
        .map((row) => StorePromotion.fromJson(Map<String, dynamic>.from(row)))
        .toList();
  }

  Future<void> save({
    required String storeId,
    String? id,
    required String name,
    required double discountPercent,
    required DateTime startsAt,
    required DateTime endsAt,
    required bool isActive,
  }) async {
    await supabase.rpc(
      'upsert_store_promotion',
      params: {
        'p_store_id': storeId,
        'p_promotion_id': id,
        'p_name': name,
        'p_discount_percent': discountPercent,
        'p_starts_at': startsAt.toUtc().toIso8601String(),
        'p_ends_at': endsAt.toUtc().toIso8601String(),
        'p_is_active': isActive,
      },
    );
  }
}

final promotionService = PromotionService();
