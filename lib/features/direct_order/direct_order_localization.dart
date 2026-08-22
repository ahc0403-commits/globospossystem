import 'direct_order_copy.dart';

const directOrderLocales = {'ko', 'vi', 'en'};

String localizedDirectOrderSnapshotName(
  Map<String, dynamic> item,
  String viewerLanguageCode,
) {
  final localizedKeys = switch (viewerLanguageCode) {
    'ko' => const ['name_ko', 'display_name_ko'],
    'en' => const ['name_en', 'display_name_en'],
    _ => const ['name_vi', 'display_name_vi'],
  };
  final fallbackKeys = <String>{
    ...localizedKeys,
    'name_vi',
    'display_name_vi',
    'display_name',
    'name_ko',
    'display_name_ko',
    'name_en',
    'display_name_en',
  };
  for (final key in fallbackKeys) {
    final value = item[key]?.toString().trim() ?? '';
    if (value.isNotEmpty) return value;
  }
  return '';
}

String localizedDirectOrderMessage({
  required DirectOrderCopy copy,
  required String? messageType,
  required String? body,
  Map<String, dynamic>? message,
}) {
  if (messageType == 'text' && message?['translation_status'] == 'complete') {
    final key = switch (copy.languageCode) {
      'ko' => 'body_ko',
      'en' => 'body_en',
      _ => 'body_vi',
    };
    final translated = message?[key]?.toString().trim() ?? '';
    if (translated.isNotEmpty) return translated;
  }
  if (messageType != 'system' && messageType != 'quote') return body ?? '';
  return switch (body) {
    'DIRECT_ORDER_REQUEST_RECEIVED' => copy.awaitingQuote,
    'DIRECT_ORDER_QUOTE_SENT' => copy.quoteReady,
    'DIRECT_ORDER_PAYMENT_APPROVED' => copy.approved,
    'DIRECT_ORDER_CANCELLED_BY_CUSTOMER' => copy.cancelled,
    null || '' => copy.systemUpdate,
    _ => body,
  };
}
