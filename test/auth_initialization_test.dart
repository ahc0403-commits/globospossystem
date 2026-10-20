import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/core/auth/terminal_auth.dart';
import 'package:globos_pos_system/core/utils/role_routes.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = '00000000-0000-0000-0000-000000000001';
const _storeId = '00000000-0000-0000-0000-000000000002';

class _AuthApi {
  int profileCalls = 0;
  int tokenRateLimits = 0;
  bool failProfile = false;
  bool failConsent = false;
  bool failLogout = false;
  String role = 'store_admin';
  String failureCode = '503';
  String failureMessage = 'temporary unavailable';
  int? failuresRemaining;
  int logoutCalls = 0;
  int consentCalls = 0;
  int storeCalls = 0;
  bool consentAccepted = true;
  bool mustChangePassword = false;
  bool active = true;
  Completer<void>? profileGate;
  Completer<void>? tokenGate;
  Completer<void>? tokenStarted;
  Completer<void>? storeGate;
  final profileStarted = Completer<void>();
  final storeStarted = Completer<void>();
  final consentStarted = Completer<void>();
  late final client = SupabaseClient(
    'http://localhost:54321',
    'test-anon-key',
    httpClient: MockClient(handle),
    authOptions: const AuthClientOptions(autoRefreshToken: false),
  );

  Future<http.Response> handle(http.Request request) async {
    Object response;
    switch (request.url.path) {
      case '/auth/v1/token':
        if (request.url.queryParameters['grant_type'] == 'refresh_token') {
          if (!(tokenStarted?.isCompleted ?? true)) tokenStarted!.complete();
          await tokenGate?.future;
        }
        if (request.url.queryParameters['grant_type'] == 'refresh_token' &&
            tokenRateLimits > 0) {
          tokenRateLimits--;
          return http.Response(
            jsonEncode({
              'error_code': 'over_request_rate_limit',
              'msg': 'Too many requests',
            }),
            429,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        final payload = base64Url
            .encode(
              utf8.encode(
                jsonEncode({
                  'sub': _userId,
                  'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
                }),
              ),
            )
            .replaceAll('=', '');
        response = {
          'access_token': 'e30.$payload.signature',
          'refresh_token': 'test-refresh',
          'expires_in': 3600,
          'token_type': 'bearer',
          'user': {
            'id': _userId,
            'aud': 'authenticated',
            'email': 'test@example.test',
            'created_at': '2026-01-01T00:00:00Z',
            'app_metadata': {},
          },
        };
      case '/rest/v1/users':
        profileCalls++;
        if (failProfile &&
            (failuresRemaining == null || failuresRemaining! > 0)) {
          if (failuresRemaining != null) {
            failuresRemaining = failuresRemaining! - 1;
          }
          return http.Response(
            jsonEncode({'message': failureMessage, 'code': failureCode}),
            503,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }
        if (!profileStarted.isCompleted) profileStarted.complete();
        await profileGate?.future;
        response = {
          'role': role,
          'restaurant_id': _storeId,
          'is_active': active,
          'extra_permissions': [],
          'must_change_password': mustChangePassword,
        };
      case '/rest/v1/restaurants':
        storeCalls++;
        if (!storeStarted.isCompleted) storeStarted.complete();
        await storeGate?.future;
        response = [
          {'id': _storeId, 'name': 'Test store'},
        ];
      case '/rest/v1/rpc/has_accepted_current_privacy_consent':
        consentCalls++;
        if (failConsent) throw http.ClientException('offline');
        if (!consentStarted.isCompleted) consentStarted.complete();
        response = consentAccepted;
      case '/auth/v1/logout':
        logoutCalls++;
        if (failLogout) throw http.ClientException('offline');
        return http.Response('', 204);
      default:
        throw StateError('Unexpected request: ${request.url.path}');
    }
    return http.Response(
      jsonEncode(response),
      200,
      headers: {'content-type': 'application/json'},
      request: request,
    );
  }
}

class _MemoryStorage implements TerminalStorage {
  final values = <String, String>{};
  @override
  Future<void> initialize() async {}
  @override
  Future<String?> read(String key) async => values[key];
  @override
  Future<void> write(String key, String value) async {
    values[key] = value;
  }

  @override
  Future<void> remove(String key) async {
    values.remove(key);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test('profile fixture decodes', () async {
    final api = _AuthApi();
    addTearDown(api.client.dispose);
    final profile = await api.client.from('users').select().single();
    expect(profile['role'], 'store_admin');
  });

  test(
    'login and signedIn share one profile load; independent checks overlap',
    () async {
      final api = _AuthApi()..storeGate = Completer<void>();
      final auth = AuthNotifier(client: api.client);
      addTearDown(auth.dispose);
      addTearDown(api.client.dispose);
      final login = auth.login('test@example.test', 'test-password');
      await api.storeStarted.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => throw StateError(
          'profile=${api.profileCalls} error=${auth.state.errorMessage}',
        ),
      );
      await api.consentStarted.future.timeout(const Duration(seconds: 3));
      expect(api.profileCalls, 1);
      expect(auth.state.user, isNull);
      expect(auth.state.isLoading, isTrue);
      api.storeGate!.complete();
      await login;
      await Future<void>.delayed(Duration.zero);
      expect(api.profileCalls, 1);
      expect(api.storeCalls, 1);
      expect(api.consentCalls, 1);
      expect(auth.state.storeId, _storeId);
      expect(auth.state.isLoading, isFalse);

      // Refresh is still fresh after initial deduplication, not cached forever.
      await auth.refreshProfile();
      expect(api.profileCalls, 2);
    },
  );

  test('late profile response cannot restore a logged-out session', () async {
    final api = _AuthApi()..profileGate = Completer<void>();
    final auth = AuthNotifier(client: api.client);
    addTearDown(auth.dispose);
    addTearDown(api.client.dispose);
    final login = auth.login('test@example.test', 'test-password');
    await api.profileStarted.future.timeout(
      const Duration(seconds: 3),
      onTimeout: () => throw StateError(
        'profile=${api.profileCalls} error=${auth.state.errorMessage}',
      ),
    );
    await auth.logout();
    api.profileGate!.complete();
    await login;
    expect(auth.state.user, isNull);
    expect(auth.state.role, isNull);
    expect(api.storeCalls, 0);
  });

  test('password and consent gates survive faster initialization', () async {
    final api = _AuthApi()
      ..consentAccepted = false
      ..mustChangePassword = true;
    final auth = AuthNotifier(client: api.client);
    addTearDown(auth.dispose);
    addTearDown(api.client.dispose);
    await auth.login('test@example.test', 'test-password');
    expect(auth.state.passwordChangeRequired, isTrue);
    expect(auth.state.privacyConsentRequired, isTrue);
  });

  test('deactivated account cannot enter the shell', () async {
    final api = _AuthApi()..active = false;
    final auth = AuthNotifier(client: api.client);
    addTearDown(auth.dispose);
    addTearDown(api.client.dispose);
    await auth.login('test@example.test', 'test-password');
    expect(auth.state.user, isNull);
    expect(auth.state.errorMessage, authErrorAccountDeactivated);
  });
  test(
    'temporary profile failure preserves existing login and recovers',
    () async {
      final api = _AuthApi();
      final auth = AuthNotifier(client: api.client);
      addTearDown(auth.dispose);
      addTearDown(api.client.dispose);
      await auth.login('test@example.test', 'test-password');
      final session = api.client.auth.currentSession;
      api.failProfile = true;
      await auth.refreshProfile();
      expect(auth.state.user?.id, _userId);
      expect(auth.state.role, 'store_admin');
      expect(auth.state.storeId, _storeId);
      expect(
        auth.state.errorMessage,
        startsWith(authErrorProfileLookupFailedPrefix),
      );
      expect(api.client.auth.currentSession, same(session));
      expect(api.logoutCalls, 0);
      api.failProfile = false;
      await auth.refreshProfile();
      expect(auth.state.errorMessage, isNull);
      expect(auth.state.user?.id, _userId);
      api.active = false;
      await auth.refreshProfile();
      expect(auth.state.user, isNull);
      expect(auth.state.errorMessage, authErrorAccountDeactivated);
      expect(api.logoutCalls, 1);
    },
  );

  for (final role in kKnownPosRoles) {
    test(
      '$role survives cold restore, outage and explicit offline logout',
      () async {
        final api = _AuthApi()..role = role;
        final storage = _MemoryStorage();
        final original = AuthNotifier(
          client: api.client,
          profileStorage: storage,
        );
        await original.login('test@example.test', 'test-password');
        expect(api.profileCalls, 1);
        expect(api.storeCalls, 1);
        expect(api.consentCalls, 1);
        original.dispose();
        api.failProfile = true;
        var resets = 0;
        final restored = AuthNotifier(
          client: api.client,
          profileStorage: storage,
          onLogout: () => resets++,
        );
        addTearDown(restored.dispose);
        addTearDown(api.client.dispose);
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(restored.state.user?.id, _userId);
        expect(restored.state.role, role);
        expect(restored.state.storeId, _storeId);
        expect(restored.state.isRecoveringSession, isTrue);
        expect(api.client.auth.currentSession, isNotNull);
        api.failProfile = false;
        await api.client.auth.refreshSession();
        await Future<void>.delayed(const Duration(milliseconds: 20));
        expect(restored.state.isRecoveringSession, isFalse);
        expect(restored.state.role, role);
        api.failLogout = true;
        await restored.logout();
        expect(resets, 1);
        expect(restored.state.user, isNull);
        expect(storage.values, isEmpty);
        expect(api.client.auth.currentSession, isNull);
      },
    );
  }

  test(
    'JWT expiry refreshes once without signing out or losing the role',
    () async {
      final api = _AuthApi();
      final auth = AuthNotifier(client: api.client);
      addTearDown(auth.dispose);
      addTearDown(api.client.dispose);
      await auth.login('test@example.test', 'test-password');
      api
        ..failProfile = true
        ..failureCode = 'PGRST303'
        ..failureMessage = 'JWT expired'
        ..failuresRemaining = 1;
      await auth.refreshProfile();
      expect(auth.state.user?.id, _userId);
      expect(auth.state.isRecoveringSession, isFalse);
      expect(api.profileCalls, 3);
      expect(api.logoutCalls, 0);
    },
  );

  test(
    'refresh-token throttling retries without deleting the session',
    () async {
      final api = _AuthApi();
      final auth = AuthNotifier(client: api.client);
      addTearDown(auth.dispose);
      addTearDown(api.client.dispose);
      await auth.login('test@example.test', 'test-password');
      api.tokenRateLimits = 1;
      await api.client.auth.refreshSession();
      expect(api.tokenRateLimits, 0);
      expect(api.client.auth.currentSession, isNotNull);
      expect(auth.state.user?.id, _userId);
      expect(api.logoutCalls, 0);
    },
  );

  test('late token refresh cannot undo an explicit logout', () async {
    final api = _AuthApi();
    final auth = AuthNotifier(client: api.client);
    addTearDown(auth.dispose);
    addTearDown(api.client.dispose);
    await auth.login('test@example.test', 'test-password');
    api
      ..tokenGate = Completer<void>()
      ..tokenStarted = Completer<void>();
    final refresh = api.client.auth.refreshSession();
    await api.tokenStarted!.future;
    await auth.logout();
    api.tokenGate!.complete();
    try {
      await refresh;
    } on AuthException {
      /* A superseded refresh is rejected. */
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.client.auth.currentSession, isNull);
    expect(auth.state.user, isNull);
  });

  test('late token refresh cannot replace a newer account', () async {
    final api = _AuthApi();
    final auth = AuthNotifier(client: api.client);
    addTearDown(auth.dispose);
    addTearDown(api.client.dispose);
    await auth.login('test@example.test', 'test-password');
    api
      ..tokenGate = Completer<void>()
      ..tokenStarted = Completer<void>();
    final refresh = api.client.auth.refreshSession();
    await api.tokenStarted!.future;
    const otherId = '00000000-0000-0000-0000-000000000003';
    final newer = api.client.auth.currentSession!.toJson();
    (newer['user'] as Map)['id'] = otherId;
    final payload = base64Url
        .encode(
          utf8.encode(
            jsonEncode({
              'sub': otherId,
              'exp': DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
            }),
          ),
        )
        .replaceAll('=', '');
    newer['access_token'] = 'e30.$payload.signature';
    newer['refresh_token'] = 'newer-mock-refresh';
    await api.client.auth.setInitialSession(jsonEncode(newer));
    api.tokenGate!.complete();
    await refresh;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(api.client.auth.currentUser?.id, otherId);
    expect(api.client.auth.currentSession?.refreshToken, 'newer-mock-refresh');
    expect(auth.state.user?.id, otherId);
    expect(api.logoutCalls, 0);
  });

  test(
    'accepted consent survives an RPC outage and fresh fallback is coalesced',
    () async {
      final api = _AuthApi();
      final auth = AuthNotifier(client: api.client);
      addTearDown(auth.dispose);
      addTearDown(api.client.dispose);
      await auth.login('test@example.test', 'test-password');
      await Future.wait(
        List.generate(20, (_) => auth.refreshProfile(force: false)),
      );
      expect(api.profileCalls, 1);
      api.failConsent = true;
      await auth.refreshProfile();
      expect(auth.state.privacyConsentRequired, isFalse);
      expect(auth.state.user, isNotNull);
    },
  );

  test(
    'missing profile blocks access but preserves the recoverable SDK session',
    () async {
      final api = _AuthApi();
      final auth = AuthNotifier(client: api.client);
      addTearDown(auth.dispose);
      addTearDown(api.client.dispose);
      await auth.login('test@example.test', 'test-password');
      api
        ..failProfile = true
        ..failureCode = 'PGRST116'
        ..failureMessage = '0 rows';
      await auth.refreshProfile();
      expect(auth.state.user, isNull);
      expect(auth.state.isRestoring, isTrue);
      expect(api.client.auth.currentSession, isNotNull);
      expect(api.logoutCalls, 0);
      api.failProfile = false;
      await api.client.auth.refreshSession();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(auth.state.user?.id, _userId);
    },
  );
}
