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
