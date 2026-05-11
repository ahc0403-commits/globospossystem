import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('language switcher is reusable and exposed in shared shells', () {
    final switcher = readRepoFile('lib/widgets/language_switcher.dart');
    final navBar = readRepoFile('lib/widgets/app_nav_bar.dart');
    final sidebar = readRepoFile('lib/core/layout/web_sidebar_layout.dart');
    final login = readRepoFile('lib/features/auth/login_screen.dart');
    final localeState = readRepoFile('lib/core/i18n/locale_state.dart');

    expect(switcher, contains('class LanguageSwitcher'));
    expect(localeState, contains("english('en')"));
    expect(localeState, contains("korean('ko')"));
    expect(localeState, contains("vietnamese('vi')"));
    expect(navBar, contains('LanguageSwitcher'));
    expect(sidebar, contains('LanguageSwitcher'));
    expect(login, contains('LanguageSwitcher'));
  });
}
