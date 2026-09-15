import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';

/// Menu names are business data, separate from the app's ARB interface copy.
/// Keep all translations until render time so an open cart or sheet can switch
/// language without another fetch. Legacy records retain their original name.
String localizedMenuName(Map<dynamic, dynamic> menu, String languageCode) {
  final language = languageCode.split(RegExp('[-_]')).first;
  final l10n = lookupAppLocalizations(
    Locale(const ['en', 'ko', 'vi'].contains(language) ? language : 'en'),
  );
  if (menu['item_type'] == 'wet_tissue_charge') {
    return l10n.cashierWetTissueCharge;
  }
  for (final key in ['name_$language', 'name', 'display_name', 'label']) {
    final value = menu[key]?.toString().trim() ?? '';
    if (value.isNotEmpty && value != 'Unknown item' && value != 'Item') {
      return value;
    }
  }
  return l10n.menuUnknownItem;
}

extension MenuLocalizationContext on BuildContext {
  String menuName(Map<dynamic, dynamic> menu) =>
      localizedMenuName(menu, Localizations.localeOf(this).languageCode);
}
