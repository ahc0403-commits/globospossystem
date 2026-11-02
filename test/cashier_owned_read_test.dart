import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/payment/payment_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Cashier extends PaymentNotifier {
  _Cashier(
    SupabaseClient client, {
    Duration budget = const Duration(seconds: 3),
  }) : super(client: client, readBudget: budget);
  final subscriptions = <String>[];
  @override
  Future<void> subscribeRealtime(String storeId) async {
    subscriptions.add(storeId);
  }
}

void main() {
  late HttpServer server;
  late SupabaseClient client;
  late _Cashier cashier;
  final calls = <({String path, String? store, String? authorization})>[];
  Completer<void>? started, release;
  var blockFirst = false, oversize = false;
  setUp(() async {
    blockFirst = oversize = false;
    calls.clear();
    started = release = null;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/health') {
        request.response.write('ok');
        await request.response.close();
        return;
      }
      final store =
          request.uri.queryParameters['id'] ??
          request.uri.queryParameters['restaurant_id'];
      calls.add((
        path: request.uri.path,
        store: store,
        authorization: request.headers.value('authorization'),
      ));
      request.response.headers.contentType = ContentType.json;
      if (blockFirst) {
        blockFirst = false;
        request.response.write('{');
        await request.response.flush();
        started!.complete();
        if (release == null) return;
        await release!.future;
        try {
          request.response.write(
            '"vat_pricing_mode":"exclusive","brands":null}',
          );
          await request.response.close();
        } catch (_) {}
        return;
      }
      request.response.write(
        oversize
            ? jsonEncode({'value': 'x' * (4 * 1024 * 1024 + 1)})
            : request.uri.path.endsWith('/restaurants')
            ? '{}'
            : '[]',
      );
      await request.response.close();
    });
    client = SupabaseClient(
      'http://127.0.0.1:${server.port}',
      'fixture',
      headers: {'Authorization': 'Bearer original-actor'},
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    cashier = _Cashier(client);
  });
  tearDown(() async {
    if (cashier.mounted) cashier.dispose();
    if (release != null && !release!.isCompleted) release!.complete();
    await client.dispose();
    await server.close(force: true);
  });
  Future<void> health() async {
    final value = await client.rest.httpClient!.get(
      Uri.parse('http://127.0.0.1:${server.port}/health'),
    );
    expect(value.body, 'ok');
  }

  test(
    'store change aborts original HTTP before follow-up order queries',
    () async {
      blockFirst = true;
      started = Completer<void>();
      final old = cashier.loadOrders('a');
      await started!.future;
      final newer = cashier.loadOrders('b');
      await Future.wait([old, newer]).timeout(const Duration(seconds: 5));
      expect(calls.where((r) => r.store == 'eq.a').map((r) => r.path), [
        '/rest/v1/restaurants',
      ]);
      expect(calls.where((r) => r.store == 'eq.b'), hasLength(3));
      expect(cashier.subscriptions, ['b']);
      expect(cashier.state.error, isNull);
      await health();
    },
  );
  test('reset during HTTP does not restore an old list or error', () async {
    blockFirst = true;
    started = Completer<void>();
    final old = cashier.loadOrders('a');
    await started!.future;
    cashier.resetOperationScope();
    await old.timeout(const Duration(seconds: 5));
    expect(calls, hasLength(1));
    expect(cashier.state.error, isNull);
    expect(cashier.subscriptions, isEmpty);
    await health();
  });
  test('disposal aborts its read without closing shared Auth', () async {
    blockFirst = true;
    started = Completer<void>();
    final old = cashier.loadOrders('a');
    await started!.future;
    cashier.dispose();
    await old.timeout(const Duration(seconds: 5));
    expect(calls, hasLength(1));
    await health();
  });
  test('one whole-job deadline stops a stalled response body', () async {
    cashier.dispose();
    cashier = _Cashier(client, budget: const Duration(milliseconds: 500));
    blockFirst = true;
    started = Completer<void>();
    final clock = Stopwatch()..start();
    await cashier.loadOrders('a');
    expect(clock.elapsed, lessThan(const Duration(seconds: 4)));
    expect(calls, hasLength(1));
    expect(cashier.state.error, contains('TimeoutException'));
    expect(cashier.subscriptions, isEmpty);
    await health();
  });
  test(
    'oversize response fails explicitly before starting more reads',
    () async {
      oversize = true;
      await cashier.loadOrders('a');
      expect(calls, hasLength(1));
      expect(cashier.state.error, contains('READ_RESPONSE_TOO_LARGE'));
      expect(cashier.subscriptions, isEmpty);
      await health();
    },
  );
  test(
    'twenty refreshes retain one active and one follow-up snapshot',
    () async {
      blockFirst = true;
      started = Completer<void>();
      release = Completer<void>();
      final initial = cashier.loadOrders('a');
      await started!.future;
      final repeated = List.generate(20, (_) => cashier.loadOrders('a'));
      release!.complete();
      await Future.wait([initial, ...repeated]);
      expect(calls.where((r) => r.path.endsWith('/restaurants')), hasLength(2));
      expect(calls.where((r) => r.path.endsWith('/orders')), hasLength(4));
    },
  );
  test('one snapshot freezes the original JWT for all related reads', () async {
    blockFirst = true;
    started = Completer<void>();
    release = Completer<void>();
    final initial = cashier.loadOrders('a');
    await started!.future;
    client.headers = {'Authorization': 'Bearer later-actor'};
    release!.complete();
    await initial;
    expect(calls, hasLength(3));
    expect(calls.map((r) => r.authorization).toSet(), {
      'Bearer original-actor',
    });
  });
}
