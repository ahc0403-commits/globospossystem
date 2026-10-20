import 'package:uuid/uuid.dart';
import 'package:web/web.dart' as web;

import 'terminal_auth.dart';

Future<TerminalAuth> createTerminalAuth(String url, List<String> args) async {
  final uri = Uri.base;
  final requested = uri.queryParameters['terminal'];
  final terminal = terminalNames.contains(requested) ? requested : null;
  // Named terminals survive window closure. Unnamed browser windows use their
  // own sessionStorage, so existing generic PWA icons also stop sharing auth.
  final namespace = terminalNamespace(url, terminal ?? 'window');
  return TerminalAuth(
    namespace: terminal == null ? '$namespace:${const Uuid().v4()}' : namespace,
    storage: WebTerminalStorage(
      namespace,
      terminal == null ? web.window.sessionStorage : web.window.localStorage,
    ),
  );
}

class WebTerminalStorage implements TerminalStorage {
  WebTerminalStorage(this.namespace, this.storage);
  final String namespace;
  final web.Storage storage;
  @override
  Future<void> initialize() async {}
  @override
  Future<String?> read(String key) async => storage.getItem('$namespace:$key');
  @override
  Future<void> write(String key, String value) async =>
      storage.setItem('$namespace:$key', value);
  @override
  Future<void> remove(String key) async =>
      storage.removeItem('$namespace:$key');
}

void openWebTerminal(String terminal) {
  if (!terminalNames.contains(terminal)) throw ArgumentError.value(terminal);
  final target = Uri.base.replace(
    queryParameters: {'terminal': terminal},
    fragment: '/login',
  );
  web.window.location.assign(target.toString());
}
