import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('app uses bundled Pretendard as the system font', () {
    final main = readRepoFile('lib/main.dart');
    final appFonts = readRepoFile('lib/core/ui/app_fonts.dart');
    final appTheme = readRepoFile('lib/core/ui/app_theme.dart');
    final pubspec = readRepoFile('pubspec.yaml');
    final bootstrap = readRepoFile('web/flutter_bootstrap.js');

    expect(main, isNot(contains('_warmUpWebKoreanFonts')));
    expect(main, isNot(contains('pendingFonts')));
    expect(appFonts, contains("family = 'Pretendard'"));
    expect(
      appFonts,
      contains("assetPath = 'assets/fonts/PretendardVariable.ttf'"),
    );
    expect(appTheme, contains('final baseTextTheme = AppFonts.textTheme();'));
    expect(pubspec, contains('family: Pretendard'));
    expect(pubspec, contains('asset: assets/fonts/PretendardVariable.ttf'));
    expect(bootstrap, contains('font-family: "Pretendard"'));
    expect(File('assets/fonts/PretendardVariable.ttf').existsSync(), isTrue);
  });

  test('runtime UI code does not depend on Google Fonts', () {
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }

      final content = entity.readAsStringSync();
      expect(
        content,
        isNot(contains('package:google_fonts/google_fonts.dart')),
      );
      expect(content, isNot(contains('GoogleFonts.')));
      expect(content, isNot(contains('PdfGoogleFonts.')));
    }
  });
}
