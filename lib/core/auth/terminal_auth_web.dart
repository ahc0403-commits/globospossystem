import 'dart:convert';
import 'package:uuid/uuid.dart';
import 'package:web/web.dart' as web;

import 'terminal_auth.dart';

Future<TerminalAuth> createTerminalAuth(String url, List<String> args) async {
  final uri = Uri.base;
  final requested = uri.queryParameters['terminal'];
  final legacyNamespace = terminalNamespace(url, 'window');
  final local = web.window.localStorage;
  final tab = web.window.sessionStorage;
  final windowPattern = RegExp(r'^window-[a-f0-9-]{36}$');
  final named = terminalNames.contains(requested);
  final tabId = tab.getItem('$legacyNamespace:terminal-id');
  final legacySession = tab.getItem('$legacyNamespace:session');
  // Preserve an already open window's independent identity. The URL keeps its
  // durable slot on restart; a generic PWA launch reopens its last active slot.
  final terminal = named || windowPattern.hasMatch(requested ?? '')
      ? requested!
      : tabId ??
            (legacySession == null
                ? local.getItem('$legacyNamespace:last-terminal')
                : null) ??
            'window-${const Uuid().v4()}';
  final namespace = terminalNamespace(url, terminal);
  if (!named) {
    tab.setItem('$legacyNamespace:terminal-id', terminal);
    local.setItem('$legacyNamespace:last-terminal', terminal);
  }
  final storage = WebTerminalStorage(namespace, local);
  if (!named && local.getItem('$namespace:migrated') == null) {
    final project = Uri.parse(url).host.split('.').first;
    final legacyKey = 'sb-$project-auth-token';
    final projectMarker = '$legacyNamespace:project-session-migrated';
    final globalSession = local.getItem(projectMarker) == null
        ? local.getItem(legacyKey)
        : null;
    final existing = legacySession ?? globalSession;
    if (await storage.read('session') == null && existing != null) {
      await storage.write('session', existing);
    }
    local.setItem('$namespace:migrated', '1');
    if (globalSession != null &&
        _sameSessionUser(await storage.read('session'), globalSession)) {
      // Consume the old shared credential once. An old app must not repopulate
      // that obsolete key and undo a later explicit logout in a fresh window.
      local.setItem(projectMarker, '1');
      local.removeItem(legacyKey);
    }
    tab.removeItem('$legacyNamespace:session');
  }
  final route = uri.fragment.isEmpty ? uri.path : uri.fragment;
  if (!route.startsWith('/order/') &&
      !route.startsWith('/qr/') &&
      !route.startsWith('/receipt') &&
      requested != terminal) {
    final target = uri.replace(
      queryParameters: {...uri.queryParameters, 'terminal': terminal},
    );
    web.window.history.replaceState(null, '', target.toString());
  }
  return TerminalAuth(namespace: namespace, storage: storage);
}

bool _sameSessionUser(String? left, String right) {
  if (left == null) return false;
  if (left == right) return true;
  try {
    final userId = jsonDecode(left)['user']['id'];
    return userId is String && userId == jsonDecode(right)['user']['id'];
  } catch (_) {
    return false;
  }
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
