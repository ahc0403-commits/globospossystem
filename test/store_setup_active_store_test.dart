import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/auth/auth_provider.dart';
import 'package:globos_pos_system/features/auth/auth_state.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'Super Admin resolves one active setup store missing from claims',
    () async {
      final fixture = _Fixture();
      await fixture.auth.setActiveStoreForSetup('store-b');
      expect(fixture.auth.state.storeId, 'store-b');
      expect(fixture.auth.state.accessibleStores.last.name, 'Store B');
      expect(fixture.requests, hasLength(1));
      expect(fixture.requests.single.url.path, '/rest/v1/restaurants');
      expect(fixture.requests.single.url.queryParameters['id'], 'eq.store-b');
      expect(
        fixture.requests.single.url.queryParameters['is_active'],
        'eq.true',
      );
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('active_store_setup-user'), 'store-b');

      await fixture.auth.setActiveStoreForSetup('store-b');
      expect(fixture.requests, hasLength(1));
    },
  );

  test(
    'ordinary store selection still requires an existing client scope',
    () async {
      final fixture = _Fixture();
      await fixture.auth.setActiveStore('store-b');
      expect(fixture.auth.state.storeId, 'store-a');
      expect(fixture.requests, isEmpty);
    },
  );

  test(
    'store admin cannot resolve a store outside their assigned scope',
    () async {
      final fixture = _Fixture(role: 'store_admin');
      await fixture.auth.setActiveStoreForSetup('store-b');
      expect(fixture.auth.state.storeId, 'store-a');
      expect(fixture.requests, isEmpty);
    },
  );

  test('inactive or missing server store cannot become active', () async {
    final fixture = _Fixture()..rows = [];
    await fixture.auth.setActiveStoreForSetup('store-b');
    expect(fixture.requests.single.url.queryParameters['is_active'], 'eq.true');
    expect(fixture.auth.state.storeId, 'store-a');
    expect(fixture.auth.state.accessibleStores, hasLength(1));
  });

  test('server permission denial leaves store and claims unchanged', () async {
    final fixture = _Fixture()..status = 403;
    await fixture.auth.setActiveStoreForSetup('store-b');
    expect(fixture.auth.state.storeId, 'store-a');
    expect(fixture.auth.state.accessibleStores, hasLength(1));
  });

  test('network failure leaves the previous store selected', () async {
    final fixture = _Fixture()..offline = true;
    await fixture.auth.setActiveStoreForSetup('store-b');
    expect(fixture.auth.state.storeId, 'store-a');
  });

  test(
    'logout during server lookup cannot restore an authenticated scope',
    () async {
      final fixture = _Fixture()..gate = Completer<void>();
      final selection = fixture.auth.setActiveStoreForSetup('store-b');
      await fixture.started.future;
      fixture.auth.clearSession();
      fixture.gate!.complete();
      await selection;
      expect(fixture.auth.state.user, isNull);
      expect(fixture.auth.state.storeId, isNull);
      expect(fixture.auth.state.accessibleStores, isEmpty);
    },
  );

  test('role downgrade during lookup cannot add the requested store', () async {
    final fixture = _Fixture()..gate = Completer<void>();
    final selection = fixture.auth.setActiveStoreForSetup('store-b');
    await fixture.started.future;
    fixture.auth.downgrade();
    fixture.gate!.complete();
    await selection;
    expect(fixture.auth.state.storeId, 'store-a');
    expect(fixture.auth.state.accessibleStores, hasLength(1));
  });
}

class _Fixture {
  _Fixture({String role = 'super_admin'}) {
    client = SupabaseClient(
      'https://setup.invalid',
      'fixture-anon',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests.add(request);
        if (!started.isCompleted) started.complete();
        await gate?.future;
        if (offline) throw http.ClientException('offline');
        return http.Response(
          jsonEncode(
            status == 200
                ? rows
                : {'code': '42501', 'message': 'permission denied'},
          ),
          status,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
    );
    auth = _Auth(client, role);
    addTearDown(() async {
      auth.dispose();
      await client.dispose();
    });
  }

  late final SupabaseClient client;
  late final _Auth auth;
  List<Map<String, dynamic>> rows = [
    {'id': 'store-b', 'name': 'Store B'},
  ];
  final requests = <http.Request>[];
  final started = Completer<void>();
  Completer<void>? gate;
  int status = 200;
  bool offline = false;
}

class _Auth extends AuthNotifier {
  _Auth(SupabaseClient client, String role) : super(client: client) {
    state = PosAuthState(
      user: User(
        id: 'setup-user',
        appMetadata: const {},
        userMetadata: const {},
        aud: 'authenticated',
        createdAt: '2026-10-19',
      ),
      role: role,
      storeId: 'store-a',
      accessibleStores: const [AccessibleStore(id: 'store-a', name: 'Store A')],
    );
  }

  void clearSession() => state = const PosAuthState();
  void downgrade() => state = state.copyWith(role: 'store_admin');
}
