import '../../l10n/app_localizations.dart';

const restaurantKitchenClosedCode = 'RESTAURANT_KITCHEN_CLOSED';
const restaurantDailySalesClosedCode = 'RESTAURANT_DAILY_SALES_CLOSED';

String localizeRestaurantCutoffError(AppLocalizations l10n, String message) {
  if (message.contains(restaurantDailySalesClosedCode)) {
    return l10n.restaurantDailySalesClosed;
  }
  if (message.contains(restaurantKitchenClosedCode)) {
    return l10n.restaurantKitchenClosed;
  }
  return message;
}
