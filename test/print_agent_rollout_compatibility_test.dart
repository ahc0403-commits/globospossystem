import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:globos_pos_system/core/hardware/print_job_agent_service.dart';

void main() {
  for (final scenario in ['current', 'missing', 'forbidden', 'unavailable']) {
    test(
      'print station rollout uses the correct claim for $scenario',
      () async {
        final calls = <String>[];
        final client = SupabaseClient(
          'https://print-station.test',
          'offline-fixture',
          httpClient: MockClient((request) async {
            final action = request.url.path.split('/').last;
            calls.add(action);
            expect(jsonDecode(request.body), {
              'p_store_id': 'store',
              'p_limit': 7,
            });
            if (action == 'claim_print_jobs_v3' && scenario != 'current') {
              final code = switch (scenario) {
                'missing' => 'PGRST202',
                'forbidden' => '42501',
                _ => 'PGRST000',
              };
              return http.Response(
                jsonEncode({
                  'code': code,
                  'message': 'Offline fixture response',
                }),
                scenario == 'missing'
                    ? 404
                    : scenario == 'forbidden'
                    ? 403
                    : 503,
                headers: {'content-type': 'application/json'},
                request: request,
              );
            }
            return http.Response(
              '[]',
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }),
        );
        addTearDown(client.dispose);
        final claim = SupabasePrintJobBackend(
          client,
        ).claimJobs('store', limit: 7);
        if (scenario == 'forbidden' || scenario == 'unavailable') {
          await expectLater(claim, throwsA(isA<PostgrestException>()));
        } else {
          expect(await claim, isEmpty);
        }
        expect(calls, [
          'claim_print_jobs_v3',
          if (scenario == 'missing') 'claim_print_jobs_v2',
        ]);
      },
    );
  }
}
