import 'package:flutter/widgets.dart';

import '../../l10n/app_localizations.dart';
import 'locale_state.dart';

enum MenuNameMatch { exact, legacyOriginal, missingTranslation }

class MenuNameResolution {
  const MenuNameResolution({
    required this.value,
    required this.language,
    required this.match,
  });

  final String value;
  final AppLanguage language;
  final MenuNameMatch match;

  bool get isExact => match == MenuNameMatch.exact;
}

/// The three registered menu names and the immutable historical/source label.
///
/// Current catalog data must provide [korean], [english], and [vietnamese].
/// [original] exists only so old orders without multilingual snapshots remain
/// identifiable; it is never treated as a successful match for a partially
/// translated current record.
class MenuNames {
  const MenuNames({
    this.original,
    this.korean,
    this.english,
    this.vietnamese,
    this.itemType,
  });

  factory MenuNames.fromMap(Map<dynamic, dynamic> source) => MenuNames(
    original: _clean(
      source['name'] ?? source['display_name'] ?? source['label'],
    ),
    korean: _clean(source['name_ko']),
    english: _clean(source['name_en']),
    vietnamese: _clean(source['name_vi']),
    itemType: _clean(source['item_type']),
  );

  final String? original;
  final String? korean;
  final String? english;
  final String? vietnamese;
  final String? itemType;

  bool get hasAnyRegisteredTranslation =>
      korean != null || english != null || vietnamese != null;

  String? forLanguage(AppLanguage language) => switch (language) {
    AppLanguage.korean => korean,
    AppLanguage.english => english,
    AppLanguage.vietnamese => vietnamese,
  };

  MenuNameResolution resolve(
    AppLanguage language, {
    required AppLocalizations l10n,
  }) {
    if (itemType == 'wet_tissue_charge') {
      return MenuNameResolution(
        value: l10n.cashierWetTissueCharge,
        language: language,
        match: MenuNameMatch.exact,
      );
    }

    final registered = forLanguage(language);
    if (registered != null) {
      return MenuNameResolution(
        value: registered,
        language: language,
        match: MenuNameMatch.exact,
      );
    }

    if (!hasAnyRegisteredTranslation && original != null) {
      return MenuNameResolution(
        value: original!,
        language: language,
        match: MenuNameMatch.legacyOriginal,
      );
    }

    return MenuNameResolution(
      value: original == null
          ? l10n.menuUnknownItem
          : l10n.menuTranslationMissing(original!),
      language: language,
      match: MenuNameMatch.missingTranslation,
    );
  }
}

String? _clean(Object? value) {
  final cleaned = value?.toString().trim() ?? '';
  if (cleaned.isEmpty || cleaned == 'Unknown item' || cleaned == 'Item') {
    return null;
  }
  return cleaned;
}

MenuNameResolution resolveMenuName(
  Map<dynamic, dynamic> menu,
  String languageCode,
) {
  final language = AppLanguage.fromCode(languageCode);
  final l10n = lookupAppLocalizations(language.locale);
  return MenuNames.fromMap(menu).resolve(language, l10n: l10n);
}

/// Compatibility entry point for existing models. All selection and fallback
/// decisions still pass through [MenuNames.resolve].
String localizedMenuName(Map<dynamic, dynamic> menu, String languageCode) =>
    resolveMenuName(menu, languageCode).value;

extension MenuLocalizationContext on BuildContext {
  String menuName(Map<dynamic, dynamic> menu) =>
      localizedMenuName(menu, Localizations.localeOf(this).languageCode);
}
