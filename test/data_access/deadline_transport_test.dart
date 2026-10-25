import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:globos_pos_system/core/utils/deadline_http_client.dart';

void main() {
  test(
    'actual HTTP body timeout cancels the request before another operation',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      final connected = Completer<void>();
      server.listen((request) async {
        request.response.headers.contentType = ContentType.json;
        request.response.write('{');
        await request.response.flush();
        if (!connected.isCompleted) connected.complete();
      });
      final inner = http.Client();
      addTearDown(inner.close);
      final client = DeadlineHttpClient(
        inner,
        DateTime.now().add(const Duration(seconds: 10)),
        // Let the socket connect on loaded/emulated runners. The unfinished
        // response body must still be cancelled at this configured budget.
        callTimeout: const Duration(seconds: 2),
      );
      final clock = Stopwatch()..start();
      await expectLater(
        client.get(Uri.parse('http://127.0.0.1:${server.port}/')),
        throwsA(isA<TimeoutException>()),
      );
      expect(clock.elapsedMilliseconds, lessThan(5000));
      expect(connected.isCompleted, isTrue);
    },
  );
  test(
    'oversized HTTP acknowledgement stops at the configured response budget',
    () async {
      final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      addTearDown(() => server.close(force: true));
      server.listen((request) async {
        request.response.write('x' * 2048);
        await request.response.close();
      });
      final inner = http.Client();
      addTearDown(inner.close);
      final client = DeadlineHttpClient(
        inner,
        DateTime.now().add(const Duration(seconds: 10)),
        maxResponseBytes: 1024,
      );
      await expectLater(
        client.get(Uri.parse('http://127.0.0.1:${server.port}/')),
        throwsA(isA<FormatException>()),
      );
    },
  );
}
