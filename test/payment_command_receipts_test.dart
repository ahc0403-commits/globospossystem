import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/payment_service.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  final result = {
    'id': 'payment',
    'order_id': 'order',
    'restaurant_id': 'store',
  };
  final receipt = {
    'operation_id': 'operation',
    'payment_id': 'payment',
    'order_id': 'order',
    'store_id': 'store',
    'result': result,
  };
  late PaymentService service;
  late SupabaseClient client;
  var calls = 0;
  Object? response;
  final requests = <http.Request>[];

  setUp(() {
    calls = 0;
    requests.clear();
    response = result;
    client = SupabaseClient(
      'https://payment-fixture.invalid',
      'fixture-anon',
      httpClient: MockClient((request) async {
        calls++;
        requests.add(request);
        return http.Response(
          jsonEncode(response),
          200,
          headers: {'content-type': 'application/json'},
          request: request,
        );
      }),
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    service = PaymentService(client: client);
  });
  tearDown(() => client.dispose());

  test(
    'one payment carries its original operation ID and normalizes its method',
    () async {
      expect(
        await service.processPaymentOnce(
          operationId: 'operation',
          orderId: 'order',
          storeId: 'store',
          amount: 8000,
          method: 'cash',
        ),
        result,
      );
      expect(calls, 1);
      expect(requests.single.url.path, '/rest/v1/rpc/process_payment_once_v1');
      expect(jsonDecode(requests.single.body), {
        'p_operation_id': 'operation',
        'p_order_id': 'order',
        'p_store_id': 'store',
        'p_amount': 8000,
        'p_method': 'CASH',
      });
    },
  );

  test(
    'one bounded lookup deduplicates IDs and never sends a payment command',
    () async {
      response = [receipt];
      final rows = await service.getPaymentCommandReceipts(
        storeId: 'store',
        operationIds: ['operation', 'operation', 'missing'],
      );
      expect(rows, [receipt]);
      expect(calls, 1);
      expect(
        requests.single.url.path,
        '/rest/v1/rpc/get_payment_command_receipts_v1',
      );
      expect(jsonDecode(requests.single.body)['p_operation_ids'], [
        'operation',
        'missing',
      ]);
    },
  );

  test('empty, oversize and invalid lookups send no request', () async {
    expect(
      await service.getPaymentCommandReceipts(
        storeId: 'store',
        operationIds: [],
      ),
      isEmpty,
    );
    for (final ids in [
      List.filled(101, 'operation'),
      [''],
    ]) {
      await expectLater(
        service.getPaymentCommandReceipts(storeId: 'store', operationIds: ids),
        throwsArgumentError,
      );
    }
    expect(calls, 0);
  });

  test(
    'a malformed confirmed payment is uncertain rather than accepted',
    () async {
      response = {...result, 'order_id': 'different-order'};
      await expectLater(
        service.processPaymentOnce(
          operationId: 'operation',
          orderId: 'order',
          storeId: 'store',
          amount: 8000,
          method: 'CASH',
        ),
        throwsFormatException,
      );
      expect(calls, 1);
    },
  );

  for (final invalid in [
    {...receipt, 'store_id': 'different-store'},
    {...receipt, 'operation_id': 'another-operation'},
    {...receipt, 'payment_id': 'different-payment'},
    {
      ...receipt,
      'result': {...result, 'order_id': 'different-order'},
    },
    {
      ...receipt,
      'result': {...result, 'restaurant_id': 'different-store'},
    },
    {...receipt, 'result': null},
  ].indexed) {
    test('rejects mismatched receipt identity ${invalid.$1}', () async {
      response = [invalid.$2];
      await expectLater(
        service.getPaymentCommandReceipts(
          storeId: 'store',
          operationIds: ['operation'],
        ),
        throwsFormatException,
      );
      expect(calls, 1);
    });
  }

  test(
    'duplicate receipts cannot substitute for another requested command',
    () async {
      response = [receipt, receipt];
      await expectLater(
        service.getPaymentCommandReceipts(
          storeId: 'store',
          operationIds: ['operation', 'missing'],
        ),
        throwsFormatException,
      );
      expect(calls, 1);
    },
  );
}
