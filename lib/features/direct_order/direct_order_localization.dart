import '../../core/i18n/menu_localization.dart';
import 'direct_order_copy.dart';

const directOrderLocales = {'ko', 'vi', 'en'};

String localizedDirectOrderSnapshotName(
  Map<String, dynamic> item,
  String viewerLanguageCode,
) {
  return localizedMenuName({
    'name':
        item['display_name'] ??
        item['name'] ??
        item['name_ko'] ??
        item['name_vi'] ??
        item['name_en'],
    'name_ko': item['name_ko'] ?? item['display_name_ko'],
    'name_vi': item['name_vi'] ?? item['display_name_vi'],
    'name_en': item['name_en'] ?? item['display_name_en'],
  }, viewerLanguageCode);
}

String localizedDirectOrderMessage({
  required DirectOrderCopy copy,
  required String? messageType,
  required String? body,
}) {
  if (messageType != 'system' && messageType != 'quote') return body ?? '';
  return switch (body) {
    'DIRECT_ORDER_REQUEST_RECEIVED' => copy.awaitingQuote,
    'DIRECT_ORDER_QUOTE_SENT' => copy.quoteReady,
    'DIRECT_ORDER_PAYMENT_APPROVED' => copy.approved,
    'DIRECT_ORDER_DELIVERY_COMPLETED' => copy.completed,
    'DIRECT_ORDER_REJECTED_BY_STORE' => copy.rejectedByStore,
    'DIRECT_ORDER_CANCELLED_BY_CUSTOMER' => copy.cancelled,
    null || '' => copy.systemUpdate,
    _ => body,
  };
}
