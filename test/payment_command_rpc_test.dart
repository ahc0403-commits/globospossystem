import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/payments/payment_command_rpc.dart';
import 'package:globos_pos_system/core/services/payment_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  late HttpServer server;
  late SupabaseClient client;
  late PaymentCommandRpc rpc;
  final requests = <Map<String, dynamic>>[];
  var stall = false, tooLarge = false, fail = false;
  setUp(() async {
    requests.clear();
    stall = false;
    tooLarge = false;
    fail = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      if (request.uri.path == '/health') {
        request.response.write('ok');
        await request.response.close();
        return;
      }
      final body = await utf8.decoder.bind(request).join();
      requests.add({'path': request.uri.path, 'body': jsonDecode(body)});
      request.response.headers.contentType = ContentType.json;
      if (stall) {
        request.response.write('{');
        await request.response.flush();
        return;
      }
      if (fail) {
        request.response.statusCode = 503;
        request.response.write(
          '{"message":"fixture unavailable","code":"PGRST000"}',
        );
      } else if (tooLarge) {
        request.response.write(jsonEncode({'value': 'x' * (513 * 1024)}));
      } else {
        request.response.write(
          '{"id":"payment","order_id":"order","restaurant_id":"store"}',
        );
      }
      await request.response.close();
    });
    client = SupabaseClient(
      'http://127.0.0.1:${server.port}',
      'fixture',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    rpc = PaymentCommandRpc(client);
  });
  tearDown(() async {
    await client.dispose();
    await server.close(force: true);
  });
  test(
    'physical response-body deadline sends once and preserves shared Auth transport',
    () async {
      stall = true;
      await expectLater(
        rpc.call(
          PaymentCommandRpcKind.execute,
          {'op': 'original'},
          isCurrent: () => true,
          budget: const Duration(seconds: 1),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(requests, hasLength(1));
      final response = await client.rest.httpClient!.get(
        Uri.parse('http://127.0.0.1:${server.port}/health'),
      );
      expect(response.body, 'ok');
    },
  );
  test(
    '503 is unknown to the caller and never automatically replays a charge',
    () async {
      fail = true;
      await expectLater(
        rpc.call(PaymentCommandRpcKind.execute, {
          'op': 'original',
        }, isCurrent: () => true),
        throwsA(isA<PostgrestException>()),
      );
      expect(requests, hasLength(1));
    },
  );
  test('payload is frozen before asynchronous Auth setup', () async {
    final input = {
      'op': 'original',
      'nested': <String, dynamic>{'amount': 100},
    };
    final result = rpc.call(
      PaymentCommandRpcKind.execute,
      input,
      isCurrent: () => true,
    );
    (input['nested'] as Map)['amount'] = 999;
    await result;
    expect((requests.single['body'] as Map)['nested'], {'amount': 100});
  });
  test(
    'oversize acknowledgement is rejected without an unbounded JSON decode',
    () async {
      tooLarge = true;
      await expectLater(
        rpc.call(PaymentCommandRpcKind.receipts, {
          'ops': ['original'],
        }, isCurrent: () => true),
        throwsFormatException,
      );
      expect(requests, hasLength(1));
    },
  );
  test('invalidated scope and oversized input send no HTTP request', () async {
    await expectLater(
      rpc.call(PaymentCommandRpcKind.execute, {
        'op': 'original',
      }, isCurrent: () => false),
      throwsStateError,
    );
    await expectLater(
      rpc.call(PaymentCommandRpcKind.execute, {
        'op': 'x' * (65 * 1024),
      }, isCurrent: () => true),
      throwsArgumentError,
    );
    expect(requests, isEmpty);
  });
  test(
    'UI payment uses the v2 count/full guard and validated native result',
    () async {
      final result = await PaymentService(client: client)
          .processSinglePaymentCommand(
            operationId: 'original',
            orderId: 'order',
            storeId: 'store',
            amount: 100,
            method: 'cash',
            expectedPaymentCount: 2,
            requireFullPayment: true,
            isCurrent: () => true,
          );
      expect(result['id'], 'payment');
      expect(
        requests.single['path'],
        '/rest/v1/rpc/process_single_payment_command_v2',
      );
      expect(requests.single['body'], {
        'p_operation_id': 'original',
        'p_order_id': 'order',
        'p_store_id': 'store',
        'p_amount': 100.0,
        'p_method': 'CASH',
        'p_expected_payment_count': 2,
        'p_require_full_payment': true,
      });
    },
  );
}
