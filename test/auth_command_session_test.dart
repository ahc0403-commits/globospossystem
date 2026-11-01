import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/auth/auth_command_session.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late HttpServer server;
  late SupabaseClient client;
  late AuthCommandSession command;
  final requests = <Map<String, dynamic>>[];
  bool stall = false, large = false, fail = false, current = true;
  Object? acknowledgement;
  setUp(() async {
    requests.clear();
    stall = large = fail = false;
    current = true;
    acknowledgement = {'password_changed': true};
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/health') {
        request.response.write('ok');
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      requests.add({
        'uri': request.uri,
        'body': body.isEmpty ? null : jsonDecode(body),
        'authorization': request.headers.value('authorization'),
      });
      request.response.headers.contentType = ContentType.json;
      if (stall) {
        request.response.write('{');
        await request.response.flush();
        return;
      }
      if (fail) {
        request.response.statusCode = 503;
        request.response.write('{"message":"unavailable","code":"PGRST000"}');
      } else {
        request.response.write(
          jsonEncode(large ? {'value': 'x' * (65 * 1024)} : acknowledgement),
        );
      }
      await request.response.close();
    });
    client = SupabaseClient(
      'http://127.0.0.1:${server.port}',
      'fixture',
      headers: {'Authorization': 'Bearer original-actor'},
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    command = AuthCommandSession(client, () => current);
  });
  tearDown(() async {
    command.close();
    await client.dispose();
    await server.close(force: true);
  });

  test('password uses original Auth and explicit self-service body', () async {
    await command.changePassword('SyntheticStrong9!', selfService: true);
    expect(
      (requests.single['uri'] as Uri).path,
      '/functions/v1/complete-initial-password-change',
    );
    expect(requests.single['authorization'], 'Bearer original-actor');
    expect(requests.single['body'], {
      'new_password': 'SyntheticStrong9!',
      'mode': 'self_service',
    });
  });

  test(
    'original JWT is retained for the follow-up own-profile lookup',
    () async {
      await command.changePassword('SyntheticStrong9!', selfService: false);
      client.headers = {'Authorization': 'Bearer later-actor'};
      acknowledgement = [
        {'must_change_password': false, 'password_change_generation': 1},
      ];
      expect(await command.passwordStillRequired('original-id'), isFalse);
      expect(requests.last['authorization'], 'Bearer original-actor');
      expect(
        (requests.last['uri'] as Uri).queryParameters['auth_id'],
        'eq.original-id',
      );
    },
  );

  test('empty profile cannot clear the password gate', () async {
    acknowledgement = [];
    await expectLater(
      command.passwordStillRequired('original-id'),
      throwsFormatException,
    );
  });

  test(
    'failed mutation is sent once and never automatically replayed',
    () async {
      fail = true;
      await expectLater(
        command.changePassword('SyntheticStrong9!', selfService: true),
        throwsStateError,
      );
      expect(requests, hasLength(1));
    },
  );

  test('missing password confirmation is not success', () async {
    acknowledgement = {'password_changed': false};
    await expectLater(
      command.changePassword('SyntheticStrong9!', selfService: true),
      throwsStateError,
    );
  });

  test('oversized response stops before JSON decoding', () async {
    large = true;
    await expectLater(
      command.changePassword('SyntheticStrong9!', selfService: true),
      throwsFormatException,
    );
    expect(requests, hasLength(1));
  });

  test(
    'stalled response is aborted and shared Auth transport stays usable',
    () async {
      stall = true;
      command.close();
      command = AuthCommandSession(
        client,
        () => current,
        budget: const Duration(seconds: 1),
      );
      await expectLater(
        command.changePassword('SyntheticStrong9!', selfService: true),
        throwsA(isA<TimeoutException>()),
      );
      command.close();
      final response = await client.rest.httpClient!.get(
        Uri.parse('http://127.0.0.1:${server.port}/health'),
      );
      expect(response.body, 'ok');
      expect(requests, hasLength(1));
    },
  );

  test(
    'invalidated context and oversized input send no HTTP request',
    () async {
      current = false;
      await expectLater(command.acceptConsent('ko'), throwsStateError);
      current = true;
      await expectLater(
        command.changePassword('x' * (17 * 1024), selfService: true),
        throwsArgumentError,
      );
      expect(requests, isEmpty);
    },
  );
}
