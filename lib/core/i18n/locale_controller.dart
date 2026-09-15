import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'locale_state.dart';

abstract interface class LocalePreferenceStore {
  Future<String?> read();

  Future<void> write(String languageCode);
}

class SharedPreferencesLocaleStore implements LocalePreferenceStore {
  const SharedPreferencesLocaleStore();

  static const prefsKey = 'app_locale';

  @override
  Future<String?> read() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(prefsKey);
  }

  @override
  Future<void> write(String languageCode) async {
    final prefs = await SharedPreferences.getInstance();
    final saved = await prefs.setString(prefsKey, languageCode);
    if (!saved) {
      throw StateError('Failed to persist the selected app locale.');
    }
  }
}

class LocaleController extends StateNotifier<AppLocaleState> {
  LocaleController({LocalePreferenceStore? store})
    : _store = store ?? const SharedPreferencesLocaleStore(),
      super(const AppLocaleState(language: AppLanguage.korean)) {
    _loadSavedLocale();
  }

  final LocalePreferenceStore _store;
  var _selectionRevision = 0;
  Future<void> _writeQueue = Future<void>.value();

  Future<void> _loadSavedLocale() async {
    final startedAtRevision = _selectionRevision;
    try {
      final savedCode = await _store.read();
      if (!mounted || startedAtRevision != _selectionRevision) return;
      state = state.copyWith(
        language: AppLanguage.fromCode(savedCode),
        isHydrated: true,
        hasPersistenceError: false,
      );
    } catch (_) {
      if (!mounted || startedAtRevision != _selectionRevision) return;
      state = state.copyWith(isHydrated: true, hasPersistenceError: true);
    }
  }

  Future<void> setLocale(AppLanguage language) async {
    if (state.language == language &&
        state.isHydrated &&
        !state.hasPersistenceError) {
      return;
    }
    final revision = ++_selectionRevision;
    state = state.copyWith(
      language: language,
      isHydrated: true,
      isPersisting: true,
      hasPersistenceError: false,
    );

    final queuedWrite = _writeQueue = _writeQueue.catchError((_) {}).then((
      _,
    ) async {
      if (!mounted || revision != _selectionRevision) return;
      await _store.write(language.code);
    });

    try {
      await queuedWrite;
      if (!mounted || revision != _selectionRevision) return;
      state = state.copyWith(isPersisting: false);
    } catch (_) {
      if (!mounted || revision != _selectionRevision) return;
      state = state.copyWith(isPersisting: false, hasPersistenceError: true);
    }
  }
}

final localeControllerProvider =
    StateNotifierProvider<LocaleController, AppLocaleState>(
      (ref) => LocaleController(),
    );
