import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/utils/owned_read_session.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Map<String, dynamic> fixtureSession(String actor, {int expiresIn = 3600}) {
  final expires = DateTime.now().millisecondsSinceEpoch ~/ 1000 + expiresIn;
  final body = base64Url
      .encode(utf8.encode(jsonEncode({'sub': actor, 'exp': expires})))
      .replaceAll('=', '');
  return {
    'access_token': 'e30.$body.fixture',
    'refresh_token': 'fixture-$actor',
    'expires_in': expiresIn,
    'token_type': 'bearer',
    'user': {
      'id': actor,
      'aud': 'authenticated',
      'created_at': '2026-11-01T00:00:00Z',
      'app_metadata': {},
      'user_metadata': {},
    },
  };
}

void main() {
  test(
    'an actor change before send cannot silently run under the new account',
    () async {
      var requests = 0;
      final client = SupabaseClient(
        'https://owned-read-fixture.invalid',
        'fixture',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests++;
          return http.Response('{}', 200, request: request);
        }),
      );
      addTearDown(client.dispose);
      await client.auth.setInitialSession(
        jsonEncode(fixtureSession('actor-a')),
      );
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final owner = OwnedReadSession(allowedRpcs: {'lookup'});
      addTearDown(owner.dispose);
      final pending = owner.run(client, (db) async {
        await gate.future;
        return db.rpc('lookup');
      });
      final rejected = expectLater(pending, throwsStateError);
      await client.auth.setInitialSession(
        jsonEncode(fixtureSession('actor-b')),
      );
      gate.complete();
      await rejected;
      expect(requests, 0);
    },
  );

  test(
    'same-actor token refresh keeps the read original authorization snapshot',
    () async {
      String? actual;
      final client = SupabaseClient(
        'https://owned-read-fixture.invalid',
        'fixture',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          actual = request.headers['Authorization'];
          return http.Response(
            '{}',
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }),
      );
      addTearDown(client.dispose);
      final original = fixtureSession('actor-a');
      await client.auth.setInitialSession(jsonEncode(original));
      final gate = Completer<void>();
      addTearDown(() {
        if (!gate.isCompleted) gate.complete();
      });
      final owner = OwnedReadSession(allowedRpcs: {'lookup'});
      addTearDown(owner.dispose);
      final pending = owner.run(client, (db) async {
        await gate.future;
        return db.rpc('lookup');
      });
      await client.auth.setInitialSession(
        jsonEncode(fixtureSession('actor-a', expiresIn: 7200)),
      );
      gate.complete();
      expect(await pending, {});
      expect(actual, 'Bearer ${original['access_token']}');
    },
  );

  test('expired Auth refresh is shared by concurrent read owners', () async {
    var authCalls = 0, readCalls = 0;
    final authStarted = Completer<void>(), authGate = Completer<void>();
    addTearDown(() {
      if (!authGate.isCompleted) authGate.complete();
    });
    final fresh = fixtureSession('actor-a');
    final client = SupabaseClient(
      'https://owned-read-fixture.invalid',
      'fixture',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        if (request.url.path.endsWith('/auth/v1/token')) {
          authCalls++;
          if (!authStarted.isCompleted) authStarted.complete();
          await authGate.future;
          return http.Response(
            jsonEncode(fresh),
            200,
            request: request,
            headers: {'content-type': 'application/json'},
          );
        }
        readCalls++;
        expect(
          request.headers['Authorization'],
          'Bearer ${fresh['access_token']}',
        );
        return http.Response(
          '{}',
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.dispose);
    await client.auth.setInitialSession(
      jsonEncode(fixtureSession('actor-a', expiresIn: -60)),
    );
    final a = OwnedReadSession(allowedRpcs: {'lookup'}),
        b = OwnedReadSession(allowedRpcs: {'lookup'});
    addTearDown(a.dispose);
    addTearDown(b.dispose);
    final first = a.run(client, (db) => db.rpc('lookup'));
    await authStarted.future.timeout(const Duration(seconds: 3));
    final second = b.run(client, (db) => db.rpc('lookup'));
    await Future<void>.delayed(Duration.zero);
    expect(authCalls, 1);
    authGate.complete();
    await Future.wait([first, second]);
    expect(authCalls, 1);
    expect(readCalls, 2);
  });

  test(
    'disposal aborts an actual response body and preserves shared Auth HTTP',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      final connected = Completer<void>();
      var healthyCalls = 0;
      server.listen((request) async {
        await request.drain<void>();
        request.response.headers.contentType = ContentType.json;
        if (request.uri.path.endsWith('/hold_read')) {
          request.response.write('{');
          await request.response.flush();
          if (!connected.isCompleted) connected.complete();
        } else {
          healthyCalls++;
          request.response.write('{"ok":true}');
          await request.response.close();
        }
      });
      final client = SupabaseClient(
        'http://127.0.0.1:${server.port}',
        'fixture',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
      );
      final first = OwnedReadSession(allowedRpcs: {'hold_read'});
      final second = OwnedReadSession(allowedRpcs: {'healthy_read'});
      addTearDown(() async {
        first.dispose();
        second.dispose();
        await client.dispose();
        await server.close(force: true);
      });
      final pending = first.run(client, (db) => db.rpc('hold_read'));
      final failure = expectLater(pending, throwsA(isA<TimeoutException>()));
      await connected.future.timeout(const Duration(seconds: 5));
      final watch = Stopwatch()..start();
      first.dispose();
      await failure;
      expect(watch.elapsedMilliseconds, lessThan(3000));
      expect(await second.run(client, (db) => db.rpc('healthy_read')), {
        'ok': true,
      });
      expect(healthyCalls, 1);
      // The parent client's ordinary requests still work after both owned closes.
      second.dispose();
      expect(await client.rpc('healthy_read'), {'ok': true});
      expect(healthyCalls, 2);
    },
  );

  test('read owners reject writes and undeclared RPCs before HTTP', () async {
    var requests = 0;
    final client = SupabaseClient(
      'https://owned-read-fixture.invalid',
      'fixture',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests++;
        return http.Response(
          '{}',
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.dispose);
    for (final command in <Future<dynamic> Function(PostgrestClient)>[
      (db) => db.from('restaurants').insert({'name': 'forbidden'}),
      (db) =>
          db.from('restaurants').update({'name': 'forbidden'}).eq('id', 'a'),
      (db) => db.from('restaurants').delete().eq('id', 'a'),
      (db) => db.rpc('process_payment'),
      (db) => db.rpc('process_payment', params: const {}, get: true),
    ]) {
      final owner = OwnedReadSession();
      await expectLater(owner.run(client, command), throwsStateError);
      owner.dispose();
    }
    expect(requests, 0);
  });

  test('one total budget covers gaps between the two allowed reads', () async {
    var requests = 0;
    final client = SupabaseClient(
      'https://owned-read-fixture.invalid',
      'fixture',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient((request) async {
        requests++;
        return http.Response(
          '{}',
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        );
      }),
    );
    addTearDown(client.dispose);
    final owner = OwnedReadSession(allowedRpcs: {'lookup'});
    addTearDown(owner.dispose);
    await expectLater(
      owner.run(client, (db) async {
        await db.rpc('lookup');
        await Future<void>.delayed(const Duration(milliseconds: 100));
        return db.rpc('lookup');
      }, budget: const Duration(milliseconds: 50)),
      throwsA(isA<TimeoutException>()),
    );
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(requests, 1);
  });

  test('response cap rejects excessive data instead of decoding it', () async {
    final client = SupabaseClient(
      'https://owned-read-fixture.invalid',
      'fixture',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode({'data': 'x' * 2048}),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(client.dispose);
    final owner = OwnedReadSession(allowedRpcs: {'lookup'});
    addTearDown(owner.dispose);
    await expectLater(
      owner.run(client, (db) => db.rpc('lookup'), maxResponseBytes: 1024),
      throwsA(
        isA<FormatException>().having(
          (e) => e.message,
          'code',
          'READ_RESPONSE_TOO_LARGE',
        ),
      ),
    );
  });

  test('disposed owners cannot start another request', () async {
    final client = SupabaseClient(
      'https://owned-read-fixture.invalid',
      'fixture',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
      httpClient: MockClient(
        (request) async => throw StateError('must not send'),
      ),
    );
    addTearDown(client.dispose);
    final owner = OwnedReadSession()..dispose();
    await expectLater(
      owner.run(client, (db) => db.from('restaurants').select('id')),
      throwsStateError,
    );
  });
}
