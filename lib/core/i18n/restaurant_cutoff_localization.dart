import '../../l10n/app_localizations.dart';

const restaurantKitchenClosedCode = 'RESTAURANT_KITCHEN_CLOSED';
const restaurantDailySalesClosedCode = 'RESTAURANT_DAILY_SALES_CLOSED';

String localizeRestaurantCutoffError(AppLocalizations l10n, String message) {
  if (message.contains('ORDER_RECOVERY_STORAGE_UNAVAILABLE')) {
    return l10n.orderRecoveryStorageUnavailable;
  }
  if (message.contains('ORDER_RECOVERY_LEGACY_REVIEW')) {
    return l10n.orderRecoveryLegacyReview;
  }
  if (message.contains('ORDER_RECOVERY_REVIEW_REQUIRED')) {
    return l10n.orderRecoveryReviewRequired;
  }
  if (message.contains('ORDER_RECOVERY_PENDING')) {
    return l10n.orderRecoveryPending;
  }
  if (message.contains('ORDER_BUSINESS_DAY_EXPIRED') ||
      message.contains('ORDER_OPERATIONS_CLOSED')) {
    return l10n.orderBusinessDayExpired;
  }
  if (message.contains(restaurantDailySalesClosedCode)) {
    return l10n.restaurantDailySalesClosed;
  }
  if (message.contains(restaurantKitchenClosedCode)) {
    return l10n.restaurantKitchenClosed;
  }
  return message;
}
