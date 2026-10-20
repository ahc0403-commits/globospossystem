@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/auth/terminal_auth.dart';
import 'package:globos_pos_system/core/auth/terminal_auth_web.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:web/web.dart' as web;

String fixtureSession(String id) => jsonEncode({
  'access_token': 'fixture-not-a-real-token',
  'refresh_token': 'fixture-refresh-$id',
  'token_type': 'bearer',
  'user': {
    'id': id,
    'app_metadata': {},
    'user_metadata': {},
    'aud': 'authenticated',
    'created_at': '2026-10-19T00:00:00Z',
  },
});

void main() {
  test(
    'legacy shared credentials migrate once and cannot undo logout',
    () async {
      const url = 'https://legacy-session-fixture.invalid';
      const legacyKey = 'sb-legacy-session-fixture-auth-token';
      final original = web.window.location.href;
      final legacy = terminalNamespace(url, 'window');
      final local = web.window.localStorage;
      final tab = web.window.sessionStorage;
      web.window.history.replaceState(
        null,
        '',
        Uri.parse(original).replace(queryParameters: {}).toString(),
      );
      local.removeItem('$legacy:last-terminal');
      local.removeItem('$legacy:project-session-migrated');
      tab.removeItem('$legacy:terminal-id');
      local.setItem(legacyKey, fixtureSession('legacy-user'));
      final migrated = await createTerminalAuth(url, []);
      expect(
        await migrated.storage.read('session'),
        fixtureSession('legacy-user'),
      );
      expect(local.getItem(legacyKey), isNull);
      await migrated.storage.remove('session');
      // A still-open old app can write its obsolete shared key again.
      local.setItem(legacyKey, fixtureSession('legacy-user'));
      web.window.history.replaceState(
        null,
        '',
        Uri.parse(original)
            .replace(
              queryParameters: {
                'terminal': 'window-00000000-0000-4000-8000-000000000002',
              },
            )
            .toString(),
      );
      final fresh = await createTerminalAuth(url, []);
      expect(await fresh.storage.read('session'), isNull);
      for (final storage in [migrated.storage, fresh.storage]) {
        await storage.remove('session');
        await storage.remove('migrated');
      }
      for (final key in [
        legacyKey,
        '$legacy:last-terminal',
        '$legacy:project-session-migrated',
      ]) {
        local.removeItem(key);
      }
      tab.removeItem('$legacy:terminal-id');
      web.window.history.replaceState(null, '', original);
    },
  );

  test('unnamed window survives close and keeps a stable isolated URL', () async {
    const url = 'https://persistent-window-fixture.invalid';
    final original = web.window.location.href;
    final legacy = terminalNamespace(url, 'window');
    final base = Uri.parse(original).replace(queryParameters: {});
    web.window.history.replaceState(null, '', base.toString());
    web.window.sessionStorage.removeItem('$legacy:terminal-id');
    web.window.localStorage.removeItem('$legacy:last-terminal');
    web.window.sessionStorage.setItem(
      '$legacy:session',
      fixtureSession('old-window'),
    );
    final auth = await createTerminalAuth(url, []);
    expect(await auth.storage.read('session'), fixtureSession('old-window'));
    final durableUrl = web.window.location.href;
    expect(
      Uri.parse(durableUrl).queryParameters['terminal'],
      startsWith('window-'),
    );
    expect(
      web.window.localStorage.getItem('${auth.namespace}:session'),
      isNotNull,
    );
    // Closing a browser discards sessionStorage, but not the terminal's session.
    web.window.sessionStorage.removeItem('$legacy:terminal-id');
    final reopened = await createTerminalAuth(url, []);
    expect(reopened.namespace, auth.namespace);
    expect(
      await reopened.storage.read('session'),
      fixtureSession('old-window'),
    );
    await reopened.storage.remove('session');
    final loggedOut = await createTerminalAuth(url, []);
    expect(await loggedOut.storage.read('session'), isNull);
    for (final key in ['session', 'migrated']) {
      web.window.localStorage.removeItem('${auth.namespace}:$key');
    }
    web.window.localStorage.removeItem('$legacy:last-terminal');
    web.window.sessionStorage.removeItem('$legacy:terminal-id');
    web.window.history.replaceState(null, '', original);
  });

  test(
    'cashier logout and legacy broadcasts leave station/display logged in',
    () async {
      final requests = <http.Request>[];
      final transport = MockClient((r) async {
        requests.add(r);
        if (r.url.path.endsWith('/token')) {
          final payload =
              jsonDecode(fixtureSession('cashier-new')) as Map<String, dynamic>;
          payload['expires_in'] = 3600;
          return http.Response(
            jsonEncode(payload),
            200,
            headers: {'content-type': 'application/json'},
            request: r,
          );
        }
        return http.Response('', 204, request: r);
      });
      final clients = <String, SupabaseClient>{};
      final stores = <String, WebTerminalStorage>{};
      final listeners = <StreamSubscription<AuthState>>[];
      for (final terminal in terminalNames) {
        final namespace = terminalNamespace(
          'https://terminal-fixture.invalid',
          terminal,
        );
        final storage = WebTerminalStorage(namespace, web.window.localStorage);
        stores[terminal] = storage;
        await storage.remove('session');
        addTearDown(() => storage.remove('session'));
        final client = SupabaseClient(
          'https://terminal-fixture.invalid',
          'fixture',
          httpClient: transport,
          authOptions: AuthClientOptions(
            autoRefreshToken: false,
            pkceAsyncStorage: TerminalPkceStorage(storage, namespace),
          ),
        );
        clients[terminal] = client;
        addTearDown(client.dispose);
        await client.auth.setInitialSession(fixtureSession(terminal));
        await TerminalSessionStorage(
          storage,
        ).persistSession(fixtureSession(terminal));
        listeners.add(
          client.auth.onAuthStateChange.listen((state) async {
            if (state.event == AuthChangeEvent.signedOut) {
              await storage.remove('session');
            }
          }),
        );
      }
      addTearDown(() async {
        for (final sub in listeners) {
          await sub.cancel();
        }
      });
      final legacy = SupabaseClient(
        'https://terminal-fixture.invalid',
        'fixture',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: transport,
      );
      addTearDown(legacy.dispose);
      // Already installed old browser apps use the original project-wide channel.
      await legacy.auth.signOut();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      for (final client in clients.values) {
        expect(client.auth.currentSession, isNotNull);
      }
      expect(requests, isEmpty);

      // Refresh/sign-in broadcasts also stay inside their terminal.
      await clients['cashier']!.auth.setInitialSession(
        fixtureSession('cashier-new'),
      );
      await clients['cashier']!.auth.refreshSession();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(clients['print_station']!.auth.currentUser!.id, 'print_station');
      expect(
        clients['customer_display']!.auth.currentUser!.id,
        'customer_display',
      );

      await clients['cashier']!.auth.signOut(scope: SignOutScope.local);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(clients['cashier']!.auth.currentSession, isNull);
      expect(await stores['cashier']!.read('session'), isNull);
      expect(
        requests
            .where((r) => r.url.path.endsWith('/logout'))
            .single
            .url
            .queryParameters['scope'],
        'local',
      );
      for (final terminal in ['print_station', 'customer_display']) {
        expect(clients[terminal]!.auth.currentUser!.id, terminal);
        final restored = Session.fromJson(
          jsonDecode((await stores[terminal]!.read('session'))!)
              as Map<String, dynamic>,
        );
        expect(restored!.user.id, terminal);
      }
    },
  );
}
