import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  test('web app warms Korean fonts before showing Flutter login UI', () {
    final main = readRepoFile('lib/main.dart');

    expect(main, contains("import 'package:google_fonts/google_fonts.dart';"));
    expect(main, contains('await _warmUpWebKoreanFonts();'));
    expect(
      main,
      contains('GoogleFonts.notoSansKr(fontWeight: FontWeight.w400)'),
    );
    expect(
      main,
      contains('GoogleFonts.notoSansKr(fontWeight: FontWeight.w700)'),
    );
    expect(
      main,
      contains('GoogleFonts.notoSansKr(fontWeight: FontWeight.w900)'),
    );
    expect(main, contains('await GoogleFonts.pendingFonts()'));
    expect(main, contains("if (!kIsWeb)"));

    final pubspec = readRepoFile('pubspec.yaml');
    expect(pubspec, contains('- assets/fonts/'));

    for (final fontFile in [
      'assets/fonts/NotoSansKR-Regular.ttf',
      'assets/fonts/NotoSansKR-Medium.ttf',
      'assets/fonts/NotoSansKR-SemiBold.ttf',
      'assets/fonts/NotoSansKR-Bold.ttf',
      'assets/fonts/NotoSansKR-ExtraBold.ttf',
      'assets/fonts/NotoSansKR-Black.ttf',
    ]) {
      expect(File(fontFile).existsSync(), isTrue);
    }
  });
}
