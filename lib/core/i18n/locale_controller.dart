import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'locale_state.dart';

class LocaleController extends StateNotifier<AppLocaleState> {
  LocaleController()
    : super(const AppLocaleState(language: AppLanguage.korean)) {
    _loadSavedLocale();
  }

  static const _prefsKey = 'app_locale';

  Future<void> _loadSavedLocale() async {
    final prefs = await SharedPreferences.getInstance();
    final savedCode = prefs.getString(_prefsKey);
    final language = AppLanguage.fromCode(savedCode);
    state = state.copyWith(language: language, isHydrated: true);
  }

  Future<void> setLocale(AppLanguage language) async {
    if (state.language == language && state.isHydrated) {
      return;
    }
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefsKey, language.code);
    state = state.copyWith(language: language, isHydrated: true);
  }
}

final localeControllerProvider =
    StateNotifierProvider<LocaleController, AppLocaleState>(
      (ref) => LocaleController(),
    );
