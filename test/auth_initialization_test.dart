import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _userId = '00000000-0000-0000-0000-000000000001';
const _storeId = '00000000-0000-0000-0000-000000000002';

class _AuthApi {
  int profileCalls = 0;
  int consentCalls = 0;
  int storeCalls = 0;
  bool consentAccepted = true;
  bool mustChangePassword = false;
  bool active = true;
  Completer<void>? profileGate;
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
        if (!profileStarted.isCompleted) profileStarted.complete();
        await profileGate?.future;
        response = {
          'role': 'store_admin',
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
        if (!consentStarted.isCompleted) consentStarted.complete();
        response = consentAccepted;
      case '/auth/v1/logout':
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
}
