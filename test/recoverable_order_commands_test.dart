import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/orders/order_intent_journal.dart';
import 'package:globos_pos_system/core/orders/recoverable_order_commands.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Deterministic client/transport tests. Separate native SQL and Chromium tests
// establish real receipt atomicity, RLS, SQLite and IndexedDB behavior.
class MemoryJournal implements OrderIntentJournal {
  List<Map<String, dynamic>> rows = [];
  bool failClaim = false, failConfirmation = false;
  @override
  Future<Map<String, dynamic>?> mutate(
    String action,
    Map<String, dynamic> input,
  ) async {
    if (failClaim && action == 'claim') {
      throw StateError('Disk full before send');
    }
    if (failConfirmation &&
        action == 'update' &&
        (input['record'] as Map)['phase'] == 'confirmed') {
      throw StateError('Disk full after commit');
    }
    final copy = (jsonDecode(jsonEncode(rows)) as List)
        .map((r) => Map<String, dynamic>.from(r as Map))
        .toList();
    final result = mutateOrderIntents(copy, action, input);
    rows = copy;
    return result;
  }

  @override
  Future<List<Map<String, dynamic>>> list(
    String project,
    String actor,
    String store,
  ) async => rows
      .where(
        (r) =>
            r['project'] == project &&
            r['actor'] == actor &&
            r['store'] == store,
      )
      .map(Map<String, dynamic>.from)
      .toList();
}

Map<String, dynamic> session(String actor) => {
  'access_token': 'synthetic-original-$actor',
  'refresh_token': 'synthetic-refresh',
  'token_type': 'bearer',
  'expires_in': 3600,
  'user': {
    'id': actor,
    'app_metadata': {},
    'user_metadata': {},
    'aud': 'authenticated',
    'created_at': '2026-11-01T00:00:00Z',
  },
};

void main() {
  late HttpServer server;
  late SupabaseClient client;
  late MemoryJournal journal;
  late RecoverableOrderCommands commands;
  final requests = <Map<String, dynamic>>[];
  final committed = <String>{};
  var unknown = false, missing = false;
  Map<String, dynamic> params(String table) => {
    'p_store_id': 'store',
    'p_table_id': table,
    'p_items': [
      {'menu_item_id': 'menu', 'quantity': 1},
    ],
    'p_business_date': '2026-11-02',
  };
  Future<dynamic> send(String operation, {String table = 'table'}) =>
      commands.execute(
        kind: 'create',
        store: 'store',
        target: table,
        operation: operation,
        params: params(table),
      );
  setUp(() async {
    requests.clear();
    committed.clear();
    unknown = missing = false;
    journal = MemoryJournal();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      final body = jsonDecode(await utf8.decoder.bind(request).join()) as Map;
      final path = request.uri.path.split('/').last;
      requests.add({'path': path, 'body': body});
      request.response.headers.contentType = ContentType.json;
      dynamic result;
      if (path.startsWith('get_order_')) {
        result = [
          for (final op in body['p_client_mutation_ids'] as List)
            if (committed.contains(op))
              {'client_mutation_id': op, 'store_id': 'store'},
        ];
      } else if (path == 'execute_order_command_batch_v1') {
        result = [
          for (final c in body['p_commands'] as List)
            {'operation': c['operation'], 'status': 'confirmed'},
        ];
      } else {
        expect(
          journal.rows.any(
            (r) =>
                r['operation'] == body['p_client_mutation_id'] &&
                r['phase'] == 'unknown',
          ),
          isTrue,
          reason: 'Intent must be durable before HTTP',
        );
        if (missing) {
          request.response.statusCode = 404;
          result = {'code': 'PGRST202', 'message': 'Missing mandatory API'};
        } else {
          committed.add(body['p_client_mutation_id'] as String);
          if (unknown) {
            request.response.statusCode = 503;
            result = {'code': 'PGRST000', 'message': 'Unknown gateway outcome'};
          } else {
            result = {'id': 'original-order', 'restaurant_id': 'store'};
          }
        }
      }
      request.response.write(jsonEncode(result));
      await request.response.close();
    });
    client = SupabaseClient(
      'http://127.0.0.1:${server.port}',
      'synthetic-public-key',
      authOptions: const AuthClientOptions(autoRefreshToken: false),
    );
    await client.auth.setInitialSession(jsonEncode(session('actor-a')));
    commands = RecoverableOrderCommands(client, journal: journal);
  });
  tearDown(() async {
    await client.dispose();
    await server.close(force: true);
  });

  test('disk failure prevents any order HTTP request', () async {
    journal.failClaim = true;
    await expectLater(send('original'), throwsStateError);
    expect(requests, isEmpty);
  });
  test(
    'unknown retains the original operation across a fresh coordinator and new UI key',
    () async {
      unknown = true;
      await expectLater(send('original'), throwsA(isA<PostgrestException>()));
      expect(requests, hasLength(1));
      expect(journal.rows, hasLength(1));
      commands = RecoverableOrderCommands(client, journal: journal);
      unknown = false;
      await send('new-ui-key');
      expect(requests.last['body']['p_client_mutation_id'], 'original');
      expect(journal.rows, isEmpty);
    },
  );
  test(
    'receipt recovery of a committed unknown never repeats the write',
    () async {
      unknown = true;
      await expectLater(send('original'), throwsA(isA<PostgrestException>()));
      await commands.recover('store');
      expect(requests.map((r) => r['path']), [
        'create_order_for_business_day',
        'get_order_create_receipts_v1',
      ]);
      expect(journal.rows, isEmpty);
    },
  );
  test('confirmed write survives local confirmation-storage failure', () async {
    journal.failConfirmation = true;
    expect((await send('original'))['id'], 'original-order');
    expect(journal.rows, hasLength(1));
    await commands.recover('store');
    expect(
      requests.where((r) => r['path'] == 'create_order_for_business_day'),
      hasLength(1),
    );
    expect(journal.rows, isEmpty);
  });
  test(
    'missing mandatory API never falls back to unkeyed order creation',
    () async {
      missing = true;
      await expectLater(send('original'), throwsA(isA<PostgrestException>()));
      expect(requests.map((r) => r['path']), ['create_order_for_business_day']);
    },
  );
  test(
    'another authenticated actor cannot replay or retire the original intent',
    () async {
      unknown = true;
      await expectLater(send('original'), throwsA(isA<PostgrestException>()));
      requests.clear();
      await client.auth.setInitialSession(jsonEncode(session('actor-b')));
      await commands.recover('store');
      expect(requests, isEmpty);
      expect(journal.rows.single['actor'], 'actor-a');
    },
  );
  test(
    '60 offline intents use two receipt reads and three bounded batches',
    () async {
      for (var n = 0; n < 60; n++) {
        final kind = n.isEven ? 'create' : 'add';
        final p = params('t$n');
        if (kind == 'add') {
          p['p_order_id'] = p.remove('p_table_id');
          p.remove('p_business_date');
        }
        await journal.mutate('claim', {
          'record': {
            'version': 1,
            'operation': 'op-$n',
            'project': commands.project,
            'actor': 'actor-a',
            'store': 'store',
            'kind': kind,
            'target': 't$n',
            'payload': jsonEncode(p),
            'createdAt': n + 1,
            'revision': 1,
            'phase': 'prepared',
          },
        });
      }
      await commands.recover('store');
      expect(requests, hasLength(5));
      expect(
        requests
            .where((r) => r['path'] == 'execute_order_command_batch_v1')
            .map((r) => (r['body']['p_commands'] as List).length),
        [20, 20, 20],
      );
      expect(journal.rows, isEmpty);
    },
  );
}
