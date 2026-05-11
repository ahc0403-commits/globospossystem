import 'package:flutter/material.dart';

enum AppLanguage {
  english('en'),
  korean('ko'),
  vietnamese('vi');

  const AppLanguage(this.code);

  final String code;

  Locale get locale => Locale(code);

  static AppLanguage fromCode(String? code) {
    return switch (code) {
      'en' => AppLanguage.english,
      'vi' => AppLanguage.vietnamese,
      _ => AppLanguage.korean,
    };
  }
}

class AppLocaleState {
  const AppLocaleState({required this.language, this.isHydrated = false});

  final AppLanguage language;
  final bool isHydrated;

  Locale get locale => language.locale;
  String get localeCode => language.code;

  AppLocaleState copyWith({AppLanguage? language, bool? isHydrated}) {
    return AppLocaleState(
      language: language ?? this.language,
      isHydrated: isHydrated ?? this.isHydrated,
    );
  }
}
