import 'package:web/web.dart' as web;

bool get customerPushEnvironmentSupported {
  final navigator = web.window.navigator;
  final appleMobile =
      RegExp('iPhone|iPad|iPod').hasMatch(navigator.userAgent) ||
      (navigator.userAgent.contains('Macintosh') &&
          navigator.maxTouchPoints > 1);
  return !appleMobile ||
      web.window.matchMedia('(display-mode: standalone)').matches;
}
