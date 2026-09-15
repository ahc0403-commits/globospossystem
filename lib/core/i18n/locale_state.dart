import 'package:flutter/material.dart';

enum AppLanguage {
  english('en'),
  korean('ko'),
  vietnamese('vi');

  const AppLanguage(this.code);

  final String code;

  Locale get locale => Locale(code);

  static AppLanguage fromCode(String? code) {
    final normalized = code
        ?.trim()
        .toLowerCase()
        .split(RegExp('[-_]'))
        .firstOrNull;
    return switch (normalized) {
      'en' => AppLanguage.english,
      'vi' => AppLanguage.vietnamese,
      _ => AppLanguage.korean,
    };
  }
}

class AppLocaleState {
  const AppLocaleState({
    required this.language,
    this.isHydrated = false,
    this.isPersisting = false,
    this.hasPersistenceError = false,
  });

  final AppLanguage language;
  final bool isHydrated;
  final bool isPersisting;
  final bool hasPersistenceError;

  Locale get locale => language.locale;
  String get localeCode => language.code;

  AppLocaleState copyWith({
    AppLanguage? language,
    bool? isHydrated,
    bool? isPersisting,
    bool? hasPersistenceError,
  }) {
    return AppLocaleState(
      language: language ?? this.language,
      isHydrated: isHydrated ?? this.isHydrated,
      isPersisting: isPersisting ?? this.isPersisting,
      hasPersistenceError: hasPersistenceError ?? this.hasPersistenceError,
    );
  }
}
