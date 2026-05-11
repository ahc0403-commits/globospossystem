import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('main wires generated localizations and locale provider', () {
    final mainFile = readRepoFile('lib/main.dart');

    expect(
      mainFile,
      contains('flutter_localizations/flutter_localizations.dart'),
    );
    expect(mainFile, contains('app_localizations.dart'));
    expect(mainFile, contains('localeControllerProvider'));
    expect(mainFile, contains('supportedLocales'));
    expect(mainFile, contains('localizationsDelegates'));
    expect(mainFile, contains('locale: localeState.locale'));
  });

  test('locale controller persists a three-language app locale state', () {
    final controller = readRepoFile('lib/core/i18n/locale_controller.dart');
    final state = readRepoFile('lib/core/i18n/locale_state.dart');

    expect(controller, contains('app_locale'));
    expect(controller, contains('SharedPreferences.getInstance()'));
    expect(controller, contains('setLocale('));
    expect(controller, contains('Locale('));
    expect(state, contains('english'));
    expect(state, contains('korean'));
    expect(state, contains('vietnamese'));
  });

  test('arb files exist for english korean and vietnamese', () {
    expect(File('lib/l10n/app_en.arb').existsSync(), isTrue);
    expect(File('lib/l10n/app_ko.arb').existsSync(), isTrue);
    expect(File('lib/l10n/app_vi.arb').existsSync(), isTrue);
  });
}
