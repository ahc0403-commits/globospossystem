import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as path;
import 'package:path_provider/path_provider.dart';

import 'terminal_auth.dart';

Future<TerminalAuth> createTerminalAuth(String url, List<String> args) async {
  final terminal =
      terminalFromArgs(args) ??
      (Platform.isWindows ? 'print_station' : 'device');
  final namespace = terminalNamespace(url, terminal);
  final support = await getApplicationSupportDirectory();
  return TerminalAuth(
    namespace: namespace,
    storage: NativeTerminalStorage(
      Directory(
        path.join(
          support.path,
          'terminal_auth_v2',
          sha256.convert(utf8.encode(namespace)).toString(),
        ),
      ),
    ),
  );
}

/// Separate files avoid SharedPreferences' process-local cache and whole-file
/// writes overwriting another terminal's refreshed session.
class NativeTerminalStorage implements TerminalStorage {
  NativeTerminalStorage(this.directory);
  final Directory directory;
  Future<void> _writes = Future.value();

  File _file(String key) => File(
    path.join(directory.path, '${sha256.convert(utf8.encode(key))}.json'),
  );

  @override
  Future<void> initialize() async => directory.create(recursive: true);

  @override
  Future<String?> read(String key) async {
    await _writes;
    final file = _file(key);
    return await file.exists() ? file.readAsString() : null;
  }

  Future<void> _serialize(Future<void> Function() action) {
    final next = _writes.then((_) => action());
    _writes = next.catchError((Object _) {});
    return next;
  }

  @override
  Future<void> write(String key, String value) => _serialize(() async {
    await initialize();
    final file = _file(key);
    final temporary = File('${file.path}.$pid.tmp');
    await temporary.writeAsString(value, flush: true);
    await temporary.rename(file.path);
  });

  @override
  Future<void> remove(String key) => _serialize(() async {
    final file = _file(key);
    if (await file.exists()) await file.delete();
  });
}

void openWebTerminal(String terminal) {}
