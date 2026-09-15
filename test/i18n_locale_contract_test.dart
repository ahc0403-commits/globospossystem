import 'package:globos_pos_system/core/i18n/locale_controller.dart';
import 'package:globos_pos_system/core/i18n/locale_state.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:io';
import 'dart:convert';
import 'dart:async';

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

class _ControlledLocaleStore implements LocalePreferenceStore {
  _ControlledLocaleStore({Completer<String?>? readCompleter})
    : readCompleter = readCompleter ?? (Completer<String?>()..complete(null));

  final Completer<String?> readCompleter;
  final List<String> writes = [];
  final List<Completer<void>> writeCompleters = [];
  bool failReads = false;
  bool failWrites = false;

  @override
  Future<String?> read() {
    if (failReads) return Future<String?>.error(StateError('read failed'));
    return readCompleter.future;
  }

  @override
  Future<void> write(String languageCode) {
    writes.add(languageCode);
    if (failWrites) return Future<void>.error(StateError('write failed'));
    final completer = Completer<void>();
    writeCompleters.add(completer);
    return completer.future;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'selected language is hydrated, updated and restored from preferences',
    () async {
      SharedPreferences.setMockInitialValues({'app_locale': 'en'});
      final controller = LocaleController();
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(controller.state.language, AppLanguage.english);
      await controller.setLocale(AppLanguage.vietnamese);
      expect(controller.state.language, AppLanguage.vietnamese);
      expect(
        (await SharedPreferences.getInstance()).getString('app_locale'),
        'vi',
      );
      final restored = LocaleController();
      addTearDown(restored.dispose);
      await Future<void>.delayed(Duration.zero);
      expect(restored.state.language, AppLanguage.vietnamese);
    },
  );
  test('locale codes normalize regional and underscore variants', () {
    expect(AppLanguage.fromCode(' EN-us '), AppLanguage.english);
    expect(AppLanguage.fromCode('vi_VN'), AppLanguage.vietnamese);
    expect(AppLanguage.fromCode('ko-KR'), AppLanguage.korean);
    expect(AppLanguage.fromCode('unsupported'), AppLanguage.korean);
  });
  test('late hydration cannot overwrite a newer operator selection', () async {
    final read = Completer<String?>();
    final store = _ControlledLocaleStore(readCompleter: read);
    final controller = LocaleController(store: store);
    addTearDown(controller.dispose);

    final selection = controller.setLocale(AppLanguage.english);
    expect(controller.state.language, AppLanguage.english);
    read.complete('vi');
    await Future<void>.delayed(Duration.zero);
    expect(controller.state.language, AppLanguage.english);

    store.writeCompleters.single.complete();
    await selection;
    expect(controller.state.language, AppLanguage.english);
    expect(controller.state.isHydrated, isTrue);
  });
  test(
    'rapid selections serialize storage and preserve the final choice',
    () async {
      final store = _ControlledLocaleStore();
      final controller = LocaleController(store: store);
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      final first = controller.setLocale(AppLanguage.english);
      await Future<void>.delayed(Duration.zero);
      final second = controller.setLocale(AppLanguage.vietnamese);
      expect(controller.state.language, AppLanguage.vietnamese);
      expect(store.writes, ['en']);

      store.writeCompleters.first.complete();
      await Future<void>.delayed(Duration.zero);
      expect(store.writes, ['en', 'vi']);
      store.writeCompleters.last.complete();
      await Future.wait([first, second]);

      expect(controller.state.language, AppLanguage.vietnamese);
      expect(controller.state.isPersisting, isFalse);
      expect(controller.state.hasPersistenceError, isFalse);
    },
  );
  test(
    'storage failures keep the selected language visible and retryable',
    () async {
      final store = _ControlledLocaleStore()..failWrites = true;
      final controller = LocaleController(store: store);
      addTearDown(controller.dispose);
      await Future<void>.delayed(Duration.zero);

      await controller.setLocale(AppLanguage.english);
      expect(controller.state.language, AppLanguage.english);
      expect(controller.state.hasPersistenceError, isTrue);
      expect(controller.state.isPersisting, isFalse);
    },
  );
  test('English and Vietnamese UI catalogs contain no Korean leftovers', () {
    for (final code in ['en', 'vi']) {
      final messages =
          jsonDecode(readRepoFile('lib/l10n/app_$code.arb')) as Map;
      final leftovers = messages.entries
          .where(
            (entry) =>
                entry.value is String &&
                RegExp(r'[가-힣]').hasMatch(entry.value as String),
          )
          .map((entry) => entry.key)
          .toList();
      expect(leftovers, isEmpty, reason: '$code contains Korean UI messages');
    }
  });
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
