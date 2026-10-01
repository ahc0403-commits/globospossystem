import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/operational_day_service.dart';
import 'package:globos_pos_system/core/utils/time_utils.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

SupabaseClient clientFor(Future<http.Response> Function(http.Request) handle) {
  final client = SupabaseClient(
    'http://localhost:54321',
    'test-anon',
    httpClient: MockClient((request) async {
      final response = await handle(request);
      return http.Response.bytes(
        response.bodyBytes,
        response.statusCode,
        headers: response.headers,
        request: request,
      );
    }),
  );
  addTearDown(client.dispose);
  return client;
}

http.Response jsonResponse(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

Map<String, dynamic> currentDay() {
  final day = TimeUtils.currentVietnamBusinessDay();
  return {
    'enabled': true,
    'business_date': day.dateKey,
    'day_start': day.startIso8601,
    'day_end': day.endIso8601,
    'cancelled_today': 2,
    'financial_reviews': [
      {
        'order_id': 'paid-order',
        'table_number': '1222',
        'business_date': '2026-09-30',
        'paid_total': 40000,
      },
    ],
  };
}

void main() {
  test('server Vietnam boundary determines expired requests precisely', () {
    final day = OperationalDayState.fromJson({
      'enabled': true,
      'business_date': '2026-10-01',
      'day_start': '2026-10-01T00:00:00+07:00',
      'day_end': '2026-10-02T00:00:00+07:00',
    });
    expect(day.window.startUtc, DateTime.utc(2026, 9, 30, 17));
    expect(day.expiresMutation(DateTime.utc(2026, 9, 30, 16, 59, 59)), isTrue);
    expect(day.expiresMutation(DateTime.utc(2026, 9, 30, 17)), isFalse);
    expect(
      OperationalDayState(
        enabled: false,
        window: day.window,
      ).expiresMutation(DateTime.utc(2026, 9, 29)),
      isFalse,
    );
  });

  test(
    'concurrent refreshes share the reset and cache is scoped by store',
    () async {
      var calls = 0;
      final pending = Completer<http.Response>();
      final service = OperationalDayService(
        client: clientFor((request) async {
          calls++;
          expect(request.url.path, '/rest/v1/rpc/ensure_store_operational_day');
          expect(
            jsonDecode(request.body)['p_store_id'],
            isIn(['store-a', 'store-b']),
          );
          return calls == 1 ? pending.future : jsonResponse(currentDay());
        }),
      );
      final first = service.ensureStoreDay('store-a');
      final second = service.ensureStoreDay('store-a');
      await Future<void>.delayed(Duration.zero);
      expect(calls, 1);
      pending.complete(jsonResponse(currentDay()));
      final states = await Future.wait([first, second]);
      expect(states.first.cancelledToday, 2);
      expect(states.first.financialReviews.single.paidTotal, 40000);
      await service.ensureStoreDay('store-a');
      expect(calls, 1);
      await service.ensureStoreDay('store-b');
      expect(calls, 2);
      service.invalidate('store-a');
      await service.ensureStoreDay('store-a');
      await service.ensureStoreDay('store-b');
      expect(calls, 3);
    },
  );

  test('an expired cached business window is refreshed immediately', () async {
    var calls = 0;
    final service = OperationalDayService(
      client: clientFor((_) async {
        calls++;
        return jsonResponse(
          currentDay()
            ..['day_end'] = DateTime.now()
                .toUtc()
                .subtract(const Duration(seconds: 1))
                .toIso8601String(),
        );
      }),
    );
    await service.ensureStoreDay('store-a');
    await service.ensureStoreDay('store-a');
    expect(calls, 2);
  });

  test('authentication failure remains an error and can be retried', () async {
    var calls = 0;
    final service = OperationalDayService(
      client: clientFor((_) async {
        calls++;
        return calls == 1
            ? jsonResponse({
                'code': '42501',
                'message': 'ORDER_MUTATION_FORBIDDEN',
              }, status: 403)
            : jsonResponse(currentDay());
      }),
    );
    await expectLater(
      service.ensureStoreDay('store-a'),
      throwsA(isA<PostgrestException>()),
    );
    expect((await service.ensureStoreDay('store-a')).enabled, isTrue);
    expect(calls, 2);
  });

  test(
    'only missing rollout RPC uses compatibility without closure columns',
    () async {
      final service = OperationalDayService(
        client: clientFor(
          (_) async => jsonResponse({
            'code': 'PGRST202',
            'message': 'Function not found',
          }, status: 404),
        ),
      );
      final day = await service.ensureStoreDay('store-a');
      expect(day.enabled, isFalse);
      expect(day.supportsClosure, isFalse);
    },
  );
}
