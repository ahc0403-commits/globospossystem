import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/attendance_service.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _storeId = '10000000-0000-0000-0000-000000000001';
const _adminId = '20000000-0000-0000-0000-000000000001';
const _employeeId = '30000000-0000-0000-0000-000000000001';

void main() {
  final rpcUrl = Platform.environment['PAYROLL_TEST_RPC_URL'];
  final dbContainer = Platform.environment['PAYROLL_TEST_DB_CONTAINER'];
  group(
    'payroll through real PostgreSQL and PostgREST',
    () {
      late HttpServer proxy;
      late HttpClient transport;
      late SupabaseClient client;
      late AttendanceService service;
      var actor = _adminId;
      var pageRequests = 0;
      Future<void> Function()? beforeSecondPage;
      Map<String, dynamic> Function(Map<String, dynamic>)? overrideSecondPage;
      final from = DateTime.utc(2026, 7, 27);
      final to = DateTime.utc(2026, 7, 28);

      Future<void> sql(String statement) async {
        final result = await Process.run('docker', [
          'exec',
          dbContainer!,
          'psql',
          '-X',
          '-v',
          'ON_ERROR_STOP=1',
          '-U',
          'postgres',
          '-d',
          'payroll_test',
          '-c',
          statement,
        ]);
        if (result.exitCode != 0) {
          throw StateError('Fixture SQL failed: ${result.stderr}');
        }
      }

      Future<void> seed(int count) => sql('''
      INSERT INTO public.attendance_logs
        (id, restaurant_id, employee_id, type, logged_at)
      SELECT ('40000000-0000-0000-0000-' || lpad(i::text, 12, '0'))::uuid,
        '$_storeId', '$_employeeId',
        CASE WHEN i % 2 = 0 THEN 'clock_out' ELSE 'clock_in' END,
        '2026-07-27 02:00:00+00'::timestamptz + (i / 3) * interval '1 microsecond'
      FROM generate_series(1, $count) i;
    ''');

      Future<List<Map<String, dynamic>>> load() =>
          service.fetchPayrollLogs(storeId: _storeId, from: from, to: to);

      setUpAll(() async {
        transport = HttpClient();
        proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        proxy.listen((request) async {
          try {
            final body = await utf8.decoder.bind(request).join();
            if (request.uri.path.endsWith('/get_payroll_attendance_page')) {
              pageRequests++;
              if (pageRequests == 2) {
                await beforeSecondPage?.call();
              }
            }
            final target = Uri.parse(rpcUrl!).resolveUri(
              request.uri.replace(
                path: request.uri.path.replaceFirst('/rest/v1', ''),
              ),
            );
            final upstream = await transport.openUrl(request.method, target);
            upstream.headers.contentType = ContentType.json;
            upstream.headers.set('x-test-actor', actor);
            upstream.write(body);
            final response = await upstream.close();
            request.response.statusCode = response.statusCode;
            request.response.headers.contentType = ContentType.json;
            if (request.uri.path.endsWith('/get_payroll_attendance_page') &&
                pageRequests == 2 &&
                overrideSecondPage != null) {
              final payload =
                  jsonDecode(await utf8.decoder.bind(response).join())
                      as Map<String, dynamic>;
              request.response.write(jsonEncode(overrideSecondPage!(payload)));
              await request.response.close();
            } else {
              await response.pipe(request.response);
            }
          } catch (error) {
            request.response.statusCode = 500;
            request.response.write(jsonEncode({'message': '$error'}));
            await request.response.close();
          }
        });
        client = SupabaseClient(
          'http://127.0.0.1:${proxy.port}',
          'fixture-key',
        );
        service = AttendanceService(client: client);
      });

      tearDownAll(() async {
        await client.dispose();
        transport.close(force: true);
        await proxy.close(force: true);
      });

      setUp(() async {
        actor = _adminId;
        pageRequests = 0;
        beforeSecondPage = null;
        overrideSecondPage = null;
        await sql('''
        TRUNCATE public.attendance_logs;
        UPDATE public.store_employees SET full_name = 'Fixture Employee';
      ''');
      });

      for (final count in [0, 499, 500, 501, 1500]) {
        test('retrieves all $count rows despite the 100-row API cap', () async {
          await seed(count);
          final rows = await load();
          expect(rows, hasLength(count));
          expect(rows.map((row) => row['id']).toSet(), hasLength(count));
          expect(pageRequests, count == 0 ? 1 : (count / 500).ceil());
          if (rows.isNotEmpty) {
            expect(rows.first['user_id'], _employeeId);
            expect(rows.first['users']['role'], 'part_timer');
            expect(
              rows.last['id'],
              '40000000-0000-0000-0000-${count.toString().padLeft(12, '0')}',
            );
          }
        });
      }

      test('display API is still bounded while payroll is complete', () async {
        await seed(1500);
        final displayRows = await service.fetchLogs(
          storeId: _storeId,
          from: from,
          to: to,
        );
        expect(displayRows, hasLength(100));
        expect(await load(), hasLength(1500));
      });

      test('keeps a half-open time range and excludes other stores', () async {
        await sql('''
        INSERT INTO public.attendance_logs(id,restaurant_id,employee_id,type,logged_at)
        VALUES
          ('40000000-0000-0000-0000-000000000001','$_storeId','$_employeeId','clock_in','2026-07-27T00:00:00Z'),
          ('40000000-0000-0000-0000-000000000002','$_storeId','$_employeeId','clock_out','2026-07-28T00:00:00Z'),
          ('40000000-0000-0000-0000-000000000003','10000000-0000-0000-0000-000000000002','$_employeeId','clock_in','2026-07-27T02:00:00Z');
      ''');
        expect(await load(), hasLength(1));
      });

      final edits = {
        'edited earlier row':
            "UPDATE public.attendance_logs SET type = 'clock_out' WHERE id = '40000000-0000-0000-0000-000000000001'",
        'deleted earlier row':
            "DELETE FROM public.attendance_logs WHERE id = '40000000-0000-0000-0000-000000000001'",
        'backfilled row before cursor':
            "INSERT INTO public.attendance_logs(id,restaurant_id,employee_id,type,logged_at) VALUES ('40000000-0000-0000-0000-000000009999','$_storeId','$_employeeId','clock_in','2026-07-27T01:00:00Z')",
        'employee metadata changed':
            "UPDATE public.store_employees SET full_name = 'Changed Employee' WHERE id = '$_employeeId'",
      };
      for (final edit in edits.entries) {
        test('rejects a mixed result when ${edit.key}', () async {
          await seed(501);
          beforeSecondPage = () => sql(edit.value);
          await expectLater(
            load(),
            throwsA(
              isA<PostgrestException>().having(
                (error) => error.message,
                'message',
                contains('PAYROLL_ATTENDANCE_CHANGED'),
              ),
            ),
          );
        });
      }

      test('rejects actors without attendance permission', () async {
        actor = '20000000-0000-0000-0000-000000000002';
        await expectLater(
          load(),
          throwsA(
            isA<PostgrestException>().having(
              (error) => error.message,
              'message',
              contains('ATTENDANCE_VIEW_FORBIDDEN'),
            ),
          ),
        );
      });

      test('rejects a store outside the actor scope', () async {
        await expectLater(
          service.fetchPayrollLogs(
            storeId: '10000000-0000-0000-0000-000000000002',
            from: from,
            to: to,
          ),
          throwsA(
            isA<PostgrestException>().having(
              (error) => error.message,
              'message',
              contains('ATTENDANCE_VIEW_FORBIDDEN'),
            ),
          ),
        );
      });

      test('rejects malformed continuation requests', () async {
        await expectLater(
          client.rpc(
            'get_payroll_attendance_page',
            params: {
              'p_store_id': _storeId,
              'p_from': from.toIso8601String(),
              'p_to': to.toIso8601String(),
              'p_after_id': _employeeId,
            },
          ),
          throwsA(
            isA<PostgrestException>().having(
              (error) => error.message,
              'message',
              contains('ATTENDANCE_QUERY_INVALID'),
            ),
          ),
        );
      });

      test('does not return partial rows after a changed revision', () async {
        await seed(501);
        overrideSecondPage = (page) => {...page, 'revision': 'changed'};
        await expectLater(
          load(),
          throwsA(
            isA<StateError>().having(
              (error) => error.message,
              'message',
              'PAYROLL_ATTENDANCE_CHANGED',
            ),
          ),
        );
      });

      test(
        'rejects a truncated final page even with a matching revision',
        () async {
          await seed(501);
          overrideSecondPage = (page) => {...page, 'rows': []};
          await expectLater(
            load(),
            throwsA(
              isA<FormatException>().having(
                (error) => error.message,
                'message',
                'PAYROLL_ATTENDANCE_INCOMPLETE',
              ),
            ),
          );
        },
      );

      test(
        'rejects an empty continuing page instead of looping forever',
        () async {
          await seed(501);
          overrideSecondPage = (page) => {
            ...page,
            'rows': [],
            'has_more': true,
          };
          await expectLater(
            load(),
            throwsA(
              isA<FormatException>().having(
                (error) => error.message,
                'message',
                'PAYROLL_ATTENDANCE_CURSOR_STALLED',
              ),
            ),
          );
          expect(pageRequests, 2);
        },
      );

      test('rejects duplicate row IDs across pages', () async {
        await seed(501);
        overrideSecondPage = (page) => {
          ...page,
          'rows': [
            {
              ...(page['rows'] as List).single as Map<String, dynamic>,
              'id': '40000000-0000-0000-0000-000000000001',
            },
          ],
        };
        await expectLater(
          load(),
          throwsA(
            isA<FormatException>().having(
              (error) => error.message,
              'message',
              'PAYROLL_ATTENDANCE_PAGE_INVALID',
            ),
          ),
        );
      });

      test('rechecks authorization on continuation pages', () async {
        await seed(501);
        beforeSecondPage = () async {
          actor = '20000000-0000-0000-0000-000000000002';
        };
        await expectLater(
          load(),
          throwsA(
            isA<PostgrestException>().having(
              (error) => error.message,
              'message',
              contains('ATTENDANCE_VIEW_FORBIDDEN'),
            ),
          ),
        );
      });
    },
    skip: rpcUrl == null || dbContainer == null
        ? 'Run scripts/test_payroll_attendance_postgrest.sh for the isolated SQL/API fixture.'
        : false,
  );
}
