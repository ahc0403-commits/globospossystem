import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/report/revenue_history_provider.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

final _range = (
  storeId: 'store-a',
  start: DateTime(2026, 8, 1),
  end: DateTime(2026, 8, 6),
);

Map<String, dynamic> _summary() => {
  'version': 1,
  'store_id': 'store-a',
  'from_date': '2026-08-01',
  'to_date': '2026-08-06',
  for (final key in [
    'dine_in',
    'delivery',
    'service',
    'cash',
    'card',
    'bank',
    'pay',
    'cancelled_amount',
    'total_orders',
    'completed_orders',
    'paid_orders',
    'open_orders',
    'cancelled_orders',
    'cancelled_items',
    'variance',
    'missing_proof_count',
    'failed_einvoice_count',
    'proof_pct',
  ])
    key: 0,
  'missing_proof': [],
  'einvoice_issues': [],
  'hourly': [],
  'methods': [],
  'daily': [
    {
      'date': '2026-08-01',
      'dine_in': 400,
      'delivery': 50,
      for (final key in ['teams', 'cash', 'card', 'bank', 'pay', 'variance'])
        key: 0,
    },
  ],
};

SupabaseClient _client(Future<http.Response> Function(http.Request) handle) {
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

http.Response _json(Object body, {int status = 200}) => http.Response(
  jsonEncode(body),
  status,
  headers: {'content-type': 'application/json'},
);

void main() {
  test('history uses one scoped aggregate for the preceding period', () async {
    var calls = 0;
    final client = _client((request) async {
      calls++;
      expect(request.url.path, '/rest/v1/rpc/get_store_report_summary');
      expect(jsonDecode(request.body), {
        'p_store_id': 'store-a',
        'p_from_date': '2026-08-01',
        'p_to_date': '2026-08-06',
      });
      return _json(_summary());
    });
    final rows = await loadRevenueHistory(client, _range);
    expect(calls, 1);
    expect(rows.single.date, DateTime(2026, 8, 1));
    expect(rows.single.total, 450);
  });

  test('a successful empty history remains distinct from a failure', () async {
    final client = _client((_) async => _json(_summary()..['daily'] = []));
    expect(await loadRevenueHistory(client, _range), isEmpty);
  });

  test('failed aggregate is propagated without raw-data fallback', () async {
    var calls = 0;
    final client = _client((_) async {
      calls++;
      return _json({'message': 'Unavailable', 'code': 'PGRST202'}, status: 404);
    });
    await expectLater(
      loadRevenueHistory(client, _range),
      throwsA(isA<PostgrestException>()),
    );
    expect(calls, 1);
  });

  for (final invalid in [
    {'version': 2},
    {'store_id': 'another-store'},
    {'from_date': '2026-07-01'},
    {'to_date': '2026-08-07'},
    {
      'daily': [
        {'date': '2026-08-01', 'dine_in': 'invalid'},
      ],
    },
  ]) {
    test('invalid aggregate is rejected: $invalid', () async {
      final client = _client((_) async => _json(_summary()..addAll(invalid)));
      await expectLater(
        loadRevenueHistory(client, _range),
        throwsFormatException,
      );
    });
  }

  test('one-day selection needs no preceding request', () async {
    final client = _client((_) async => throw StateError('Unexpected request'));
    expect(
      await loadRevenueHistory(client, (
        storeId: 'store-a',
        start: DateTime(2026, 8, 1),
        end: DateTime(2026, 7, 31),
      )),
      isEmpty,
    );
  });
}
