import '../../core/menu/menu_choices.dart';
import 'direct_order_copy.dart';
import 'direct_order_models.dart';

// Storefront-specific copy stays out of the broadly shared DirectOrderCopy file.
extension DirectOrderDeliveryQualityCopy on DirectOrderCopy {
  String get deliveryQualityNotice => switch (languageCode) {
    'ko' => '음식의 특성상 배달 시간에 따라 맛과 식감이 달라질 수 있습니다.',
    'en' => 'Taste and texture may vary depending on delivery time.',
    _ =>
      'Hương vị và kết cấu món ăn có thể thay đổi tùy theo thời gian giao hàng.',
  };
}

// BunsikClub Binh Thanh's catalog identities, verified read-only on 2026-11-01.
// Never infer this policy from translated names or apply it to another store.
const deliveryQualityNoticeStoreId = '8bc9eef5-dcd5-46b1-b931-23f77132322c';
const deliveryQualityNoticeMenuIds = {
  'b3520540-6722-4782-97e4-11debf7d63e5', // Spicy pork kimbap
  'e4181065-c4c1-45d3-bdae-de0b31feed81', // Bulgogi kimbap
  '8182aa51-628f-40dd-93c4-f60f1347157b', // Buldak egg stir-fried noodles
};

bool showsDeliveryQualityNotice({
  required String? storeId,
  required DirectOrderMenuItem item,
  required bool pickup,
}) {
  if (pickup || item.isCombo || storeId != deliveryQualityNoticeStoreId) {
    return false;
  }
  final menuId = item.sizeMetadata?.menuId ?? menuChoiceBaseId(item.id);
  return deliveryQualityNoticeMenuIds.contains(menuId);
}
