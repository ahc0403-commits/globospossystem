import 'package:supabase_flutter/supabase_flutter.dart';

import 'terminal_auth_native.dart'
    if (dart.library.js_interop) 'terminal_auth_web.dart'
    as platform;

const terminalNames = {
  'cashier',
  'print_station',
  'customer_display',
  'kitchen',
  'waiter',
  'emergency_station',
  'floor_1f',
  'floor_2f',
  'floor_3f',
  'tray',
  'inventory',
  'admin',
};

/// A terminal is a login space, not an authorization role. Server permissions
/// still come from the authenticated account and RLS.
class TerminalAuth {
  TerminalAuth({required this.namespace, required this.storage});

  final String namespace;
  final TerminalStorage storage;

  static Future<TerminalAuth> create(
    String projectUrl,
    List<String> args,
  ) async {
    final auth = await platform.createTerminalAuth(projectUrl, args);
    current = auth;
    return auth;
  }

  static TerminalAuth? current;

  FlutterAuthClientOptions get options => FlutterAuthClientOptions(
    localStorage: TerminalSessionStorage(storage),
    pkceAsyncStorage: TerminalPkceStorage(storage, namespace),
  );
}

abstract class TerminalStorage {
  Future<void> initialize();
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> remove(String key);
}

class TerminalSessionStorage extends LocalStorage {
  const TerminalSessionStorage(this.storage);
  final TerminalStorage storage;

  @override
  Future<void> initialize() => storage.initialize();
  @override
  Future<bool> hasAccessToken() async => await accessToken() != null;
  @override
  Future<String?> accessToken() => storage.read('session');
  @override
  Future<void> persistSession(String persistSessionString) =>
      storage.write('session', persistSessionString);
  @override
  Future<void> removePersistedSession() => storage.remove('session');
}

class TerminalPkceStorage extends GotrueAsyncStorage {
  const TerminalPkceStorage(this.storage, this.namespace);
  final TerminalStorage storage;
  final String namespace;

  @override
  String get authBroadcastChannelKey => namespace;
  @override
  Future<String?> getItem({required String key}) => storage.read('pkce-$key');
  @override
  Future<void> setItem({required String key, required String value}) =>
      storage.write('pkce-$key', value);
  @override
  Future<void> removeItem({required String key}) => storage.remove('pkce-$key');
}

String? terminalFromArgs(List<String> args) {
  for (final arg in args) {
    if (arg.startsWith('--terminal=')) {
      final name = arg.substring('--terminal='.length);
      if (!terminalNames.contains(name)) {
        throw ArgumentError.value(name, 'terminal');
      }
      return name;
    }
  }
  return null;
}

String terminalNamespace(String projectUrl, String terminal) =>
    'globos-auth-v2:${Uri.parse(projectUrl).host}:$terminal';

void openWebTerminal(String terminal) => platform.openWebTerminal(terminal);
