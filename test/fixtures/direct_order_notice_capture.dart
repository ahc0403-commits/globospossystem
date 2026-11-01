import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/ui/app_fonts.dart';

const noticeCaptureKey = Key('delivery_notice_capture');

Future<void> loadNoticeFont() async {
  final fonts = FontLoader(AppFonts.family)
    ..addFont(rootBundle.load(AppFonts.assetPath));
  await fonts.load();
  final icons = FontLoader('MaterialIcons')
    ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
  await icons.load();
}

// Optional observation artifacts. Assertions remain independent of these images;
// this is neither a golden baseline update nor production/browser evidence.
Future<void> captureNotice(WidgetTester tester, String name) async {
  const directory = String.fromEnvironment('NOTICE_OUTPUT');
  if (directory.isEmpty) return;
  final boundary = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(noticeCaptureKey),
  );
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 1);
    final png = await image.toByteData(format: ui.ImageByteFormat.png);
    await Directory(directory).create(recursive: true);
    await File('$directory/$name.png').writeAsBytes(png!.buffer.asUint8List());
    image.dispose();
  });
}
