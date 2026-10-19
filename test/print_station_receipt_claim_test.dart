import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:globos_pos_system/core/hardware/print_job_agent_service.dart';

void main() {
  test(
    'paperless uses one receipt-only claim and never falls back on missing RPC',
    () async {
      final paths = <String>[];
      final client = SupabaseClient(
        'https://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          expect(jsonDecode(request.body), {
            'p_store_id': 'store-a',
            'p_limit': 10,
          });
          return http.Response(
            jsonEncode({
              'code': 'PGRST202',
              'message': 'missing receipt claim',
            }),
            404,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final backend = SupabasePrintJobBackend(client);
      await expectLater(
        backend.claimJobs('store-a', receiptOnly: true),
        throwsA(isA<PostgrestException>()),
      );
      expect(paths, ['/rest/v1/rpc/claim_print_station_receipt_jobs']);
      await client.dispose();
    },
  );

  test(
    'receipt preflight sends zero limit and normal mode retains v3',
    () async {
      final paths = <String>[];
      final limits = <int>[];
      final client = SupabaseClient(
        'https://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          paths.add(request.url.path);
          limits.add((jsonDecode(request.body) as Map)['p_limit'] as int);
          return http.Response(
            '[]',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final backend = SupabasePrintJobBackend(client);
      await backend.claimJobs('store-a', receiptOnly: true, limit: 0);
      await backend.claimJobs('store-a');
      expect(paths, [
        '/rest/v1/rpc/claim_print_station_receipt_jobs',
        '/rest/v1/rpc/claim_print_jobs_v3',
      ]);
      expect(limits, [0, 10]);
      await client.dispose();
    },
  );
}
