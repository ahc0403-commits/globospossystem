// Explicit --enable-vmservice entrypoint, outside the default *_test.dart glob.
// Uses an owned test VM and synthetic HTTP; never connects to a POS service.
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/kds_realtime_sync.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

Future<int> liveIsolates() async {
  final info = await developer.Service.getInfo();
  final uri = info.serverUri;
  if (uri == null || !{'127.0.0.1', 'localhost', '::1'}.contains(uri.host)) {
    throw StateError(
      'Run this owned VM probe with flutter test --enable-vmservice',
    );
  }
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 3);
  try {
    final request = await client.getUrl(uri.resolve('getVM'));
    final response = await request.close().timeout(const Duration(seconds: 3));
    final raw = await response
        .transform(utf8.decoder)
        .join()
        .timeout(const Duration(seconds: 3));
    final payload = jsonDecode(raw) as Map;
    if (response.statusCode != 200 || payload['result']?['isolates'] is! List) {
      throw StateError('Owned VM resource snapshot unavailable');
    }
    return (payload['result']['isolates'] as List).length;
  } finally {
    client.close(force: true);
  }
}

void main() {
  test(
    '100 denied actual KDS RPC reads also release native JSON workers',
    () async {
      var requests = 0;
      final client = SupabaseClient(
        'https://native-resource-fixture.invalid',
        'fixture',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests++;
          return http.Response(
            '{"code":"42501","message":"fixture denied"}',
            403,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final gateway = SupabaseKdsSyncGateway(client);
      await expectLater(
        gateway.loadConfig(),
        throwsA(isA<PostgrestException>()),
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final before = await liveIsolates();
      for (var i = 0; i < 100; i++) {
        await expectLater(
          gateway.loadConfig(),
          throwsA(isA<PostgrestException>()),
        );
      }
      var after = await liveIsolates();
      for (var i = 0; i < 20 && after > before; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        after = await liveIsolates();
      }
      stdout.writeln(
        'NATIVE_KDS_RPC_FAILURE_RESOURCES=${jsonEncode({'beforeIsolates': before, 'afterIsolates': after, 'requests': requests, 'measuredCalls': 100, 'concurrency': 1, 'productionModified': false})}',
      );
      expect(requests, 101);
      expect(after, lessThanOrEqualTo(before));
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    '100 actual KDS RPC reads return native JSON workers to baseline',
    () async {
      var requests = 0;
      final client = SupabaseClient(
        'https://native-resource-fixture.invalid',
        'fixture',
        authOptions: const AuthClientOptions(autoRefreshToken: false),
        httpClient: MockClient((request) async {
          requests++;
          expect(request.url.path, '/rest/v1/rpc/get_kds_sync_config');
          return http.Response(
            '{"mode":"legacy","revision":0,"assigned":false}',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      addTearDown(client.dispose);
      final gateway = SupabaseKdsSyncGateway(client);
      await gateway.loadConfig();
      await Future<void>.delayed(const Duration(milliseconds: 100));
      final before = await liveIsolates();
      final watch = Stopwatch()..start();
      for (var i = 0; i < 100; i++) {
        expect((await gateway.loadConfig()).mode, KdsSyncMode.legacy);
      }
      watch.stop();
      var after = await liveIsolates();
      for (var i = 0; i < 20 && after > before; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        after = await liveIsolates();
      }
      // Counts come from the VM service, not a counter mirroring application code.
      stdout.writeln(
        'NATIVE_KDS_RPC_RESOURCES=${jsonEncode({'beforeIsolates': before, 'afterIsolates': after, 'requests': requests, 'measuredCalls': 100, 'concurrency': 1, 'wallMs': watch.elapsedMilliseconds, 'productionModified': false})}',
      );
      expect(requests, 101);
      expect(
        after,
        lessThanOrEqualTo(before),
        reason: 'request-owned JSON isolates must exit',
      );
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );
}
