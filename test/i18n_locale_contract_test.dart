import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

const arbFiles = [
  'lib/l10n/app_en.arb',
  'lib/l10n/app_ko.arb',
  'lib/l10n/app_vi.arb',
];

List<String> readTopLevelArbKeys(String path) {
  final keyPattern = RegExp(r'^  "([^"]+)":');
  return File(path)
      .readAsLinesSync()
      .map((line) => keyPattern.firstMatch(line)?.group(1))
      .whereType<String>()
      .toList();
}

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

  test('arb files do not define duplicate top-level keys', () {
    for (final path in arbFiles) {
      final counts = <String, int>{};
      for (final key in readTopLevelArbKeys(path)) {
        counts[key] = (counts[key] ?? 0) + 1;
      }
      final duplicates =
          counts.entries
              .where((entry) => entry.value > 1)
              .map((entry) => entry.key)
              .toList()
            ..sort();

      expect(duplicates, isEmpty, reason: '$path has duplicate ARB keys');
    }
  });

  test('arb files expose the same key set across supported locales', () {
    final englishKeys = readTopLevelArbKeys('lib/l10n/app_en.arb').toSet();

    for (final path in arbFiles.skip(1)) {
      final localeKeys = readTopLevelArbKeys(path).toSet();
      final missing = englishKeys.difference(localeKeys).toList()..sort();
      final extra = localeKeys.difference(englishKeys).toList()..sort();

      expect(missing, isEmpty, reason: '$path is missing ARB keys');
      expect(extra, isEmpty, reason: '$path has extra ARB keys');
    }
  });
}
