import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/attendance_service.dart';
import 'package:globos_pos_system/core/services/financial_input_service.dart';
import 'package:globos_pos_system/core/services/payroll_service.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _store = '10000000-0000-0000-0000-000000000001';
const _otherStore = '10000000-0000-0000-0000-000000000002';
const _admin = '20000000-0000-0000-0000-000000000001';
const _superAdmin = '20000000-0000-0000-0000-000000000003';
const _employee = '30000000-0000-0000-0000-000000000001';

// Only wage policy is fixed here; attendance and all supplemental inputs use
// the real SQL/API. Wage policy batching is a separate performance phase.
class _PayrollInputs extends AttendanceService {
  _PayrollInputs(SupabaseClient client) : super(client: client);

  @override
  Future<Map<String, dynamic>?> fetchHourlyPayRule({
    required String storeId,
    required String employeeId,
  }) async => {
    'hourly_rate': 100,
    'scheduled_start': '00:00',
    'exclude_sunday': false,
  };
}

class _AdminReports extends SuperAdminNotifier {
  _AdminReports(SupabaseClient client) : super(client: client);

  void setStores(List<String> ids) {
    state = state.copyWith(
      restaurants: [
        for (final id in ids)
          SuperRestaurant(
            id: id,
            name: id,
            slug: id,
            address: '',
            operationMode: 'standard',
            perPersonCharge: null,
            isActive: true,
            createdAt: DateTime(2026),
          ),
      ],
    );
  }
}

void main() {
  final rpcUrl = Platform.environment['FINANCIAL_TEST_RPC_URL'];
  final dbContainer = Platform.environment['FINANCIAL_TEST_DB_CONTAINER'];
  group(
    'complete financial inputs through PostgreSQL and PostgREST',
    () {
      late HttpServer proxy;
      late HttpClient transport;
      late SupabaseClient client;
      late FinancialInputService service;
      var actor = _admin;
      final requests = <String, int>{};
      Future<void> Function(String source, int page)? beforePage;
      Map<String, dynamic> Function(
        String source,
        int page,
        Map<String, dynamic> payload,
      )?
      overridePage;

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
      INSERT INTO store_employees(id,store_id,employee_number,full_name,employment_role)
      SELECT ('30000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
        '$_store', lpad(i::text,12,'0'), 'Employee ' || i, 'part_timer'
      FROM generate_series(1,$count) i;
      INSERT INTO employee_daily_allowances
      SELECT ('41000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
        '$_store', ('30000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
        '2026-07-27', true, 20, 3 FROM generate_series(1,$count) i;
      INSERT INTO vietnam_public_holidays
      SELECT '2024-01-01'::date + i - 1, true FROM generate_series(1,$count) i;
      INSERT INTO orders
      SELECT ('50000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
        '$_store', 'completed', 'dine_in', '2026-07-27 02:00:00+00'
      FROM generate_series(1,$count) i;
      INSERT INTO payments
      SELECT ('60000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
        '$_store', ('50000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
        110, 100, 'CASH', '2026-07-27 02:00:00+00', true, '', true
      FROM generate_series(1,$count) i;
      INSERT INTO payments
      SELECT ('61000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
        '$_store', NULL, 5, NULL, 'CASH', '2026-07-27 02:00:00+00', false, NULL, false
      FROM generate_series(1,$count) i;
      INSERT INTO external_sales
      SELECT ('70000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
        '$_store', 10, '2026-07-27 02:00:00+00', true, 'completed'
      FROM generate_series(1,$count) i;
      INSERT INTO order_items
      SELECT ('80000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
        ('50000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid, 'cancelled'
      FROM generate_series(1,$count) i;
      INSERT INTO meinvoice_jobs
      SELECT ('90000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
        '$_store', ('50000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
        'failed', 'fixture error', NULL, '2026-07-27 02:00:00+00'
      FROM generate_series(1,$count) i;
      INSERT INTO photo_objet_sales
      SELECT ('a0000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
        '$_store', '2024-01-01'::date + i - 1, 50, 2, 2
      FROM generate_series(1,$count) i;
    ''');

      Future<List<Map<String, dynamic>>> load(
        FinancialInputSource source, {
        List<String> stores = const [_store],
      }) => service.fetch(
        source: source,
        storeIds: stores,
        from: DateTime.utc(2024),
        toExclusive: DateTime.utc(2030),
        fromDate: '2024-01-01',
        toDate: '2029-12-31',
      );

      setUpAll(() async {
        transport = HttpClient();
        proxy = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
        proxy.listen((request) async {
          try {
            final body = await utf8.decoder.bind(request).join();
            final isPage = request.uri.path.endsWith(
              '/get_financial_input_page',
            );
            final source = isPage
                ? (jsonDecode(body) as Map)['p_source'] as String
                : '';
            final page = isPage ? (requests[source] ?? 0) + 1 : 0;
            if (isPage) {
              requests[source] = page;
              await beforePage?.call(source, page);
            }
            final upstream = await transport.openUrl(
              request.method,
              Uri.parse(rpcUrl!).resolveUri(
                request.uri.replace(
                  path: request.uri.path.replaceFirst('/rest/v1', ''),
                ),
              ),
            );
            upstream.headers.contentType = ContentType.json;
            if (actor.isNotEmpty) upstream.headers.set('x-test-actor', actor);
            upstream.write(body);
            final response = await upstream.close();
            request.response.statusCode = response.statusCode;
            request.response.headers.contentType = ContentType.json;
            final data = await utf8.decoder.bind(response).join();
            request.response.write(
              isPage && response.statusCode == 200 && overridePage != null
                  ? jsonEncode(
                      overridePage!(
                        source,
                        page,
                        jsonDecode(data) as Map<String, dynamic>,
                      ),
                    )
                  : data,
            );
            await request.response.close();
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
        service = FinancialInputService(client);
      });
      tearDownAll(() async {
        await client.dispose();
        transport.close(force: true);
        await proxy.close(force: true);
      });
      setUp(() async {
        actor = _admin;
        requests.clear();
        beforePage = null;
        overridePage = null;
        await sql(
          'TRUNCATE attendance_logs, store_employees, employee_daily_allowances, '
          'vietnam_public_holidays, payments, orders, order_items, external_sales, '
          'meinvoice_jobs, photo_objet_sales;',
        );
      });

      test(
        'reproduces silent row caps on the former direct table and view reads',
        () async {
          await seed(501);
          expect(
            await client.from('store_employees').select('id'),
            hasLength(100),
          );
          final oldAllowances = await client
              .from('employee_daily_allowances')
              .select('meal_allowance_amount');
          expect(
            oldAllowances.fold<num>(
              0,
              (sum, row) => sum + (row['meal_allowance_amount'] as num),
            ),
            2000,
          );
          expect(
            await client.from('payments').select('id').eq('is_revenue', true),
            hasLength(100),
          );
          expect(
            await client.from('v_photo_objet_daily_summary').select('store_id'),
            hasLength(100),
          );
          expect(await load(FinancialInputSource.allowances), hasLength(501));
        },
      );

      for (final count in [0, 499, 500, 501, 1500]) {
        test(
          'every allowed projection returns $count rows through a 100-row API cap',
          () async {
            await seed(count);
            for (final source in FinancialInputSource.values) {
              final rows = await load(source);
              expect(rows, hasLength(count), reason: source.name);
              expect(
                requests[source.name],
                count == 0 ? 1 : (count / 500).ceil(),
              );
              expect(rows.any((row) => row.containsKey('_cursor')), isFalse);
            }
          },
        );
      }

      test(
        'payroll includes allowances past row 500 and staff with no attendance',
        () async {
          await seed(501);
          await sql('''
        INSERT INTO attendance_logs(id,restaurant_id,employee_id,type,logged_at)
        SELECT ('b0000000-0000-0000-0000-' || lpad((i*2+k)::text,12,'0'))::uuid,
          '$_store', ('30000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
          CASE WHEN k=0 THEN 'clock_in' ELSE 'clock_out' END,
          '2026-07-27 02:00:00+00'::timestamptz + k * interval '1 hour'
        FROM generate_series(1,501) i CROSS JOIN generate_series(0,1) k;
        INSERT INTO store_employees VALUES
          ('30000000-0000-0000-0000-000000009999','No attendance','part_timer','999999999999','$_store',true);
      ''');
          final source = _PayrollInputs(client);
          final payroll = await PayrollService(attendanceSource: source)
              .calculatePayroll(
                storeId: _store,
                periodStart: DateTime(2026, 7, 27),
                periodEnd: DateTime(2026, 7, 27),
              );
          expect(payroll, hasLength(502));
          expect(
            payroll.fold<double>(0, (sum, row) => sum + row.totalHours),
            501,
          );
          expect(
            payroll.fold<double>(0, (sum, row) => sum + row.totalMealAllowance),
            501 * 20,
          );
          expect(
            payroll.fold<double>(
              0,
              (sum, row) => sum + row.totalParkingAllowance,
            ),
            501 * 3,
          );
          expect(
            payroll.fold<double>(0, (sum, row) => sum + row.totalAmount),
            501 * 123,
          );
          expect(
            payroll
                .singleWhere((row) => row.userName == 'No attendance')
                .totalAmount,
            0,
          );
          expect(
            await source.fetchVietnamPublicHolidays(
              from: DateTime(2024),
              to: DateTime(2029, 12, 31),
            ),
            hasLength(501),
          );
        },
      );

      test(
        'report keeps sales, received cash, service, issues and counts complete',
        () async {
          await seed(501);
          final report = ReportNotifier(client: client);
          addTearDown(report.dispose);
          await report.setDateRange(
            DateTime(2024),
            DateTime(2029, 12, 31),
            _store,
          );
          expect(report.state.error, isNull);
          final summary = report.state.summary!;
          expect(summary.dineInRevenue, 501 * 148);
          expect(summary.deliveryRevenue, 501 * 10);
          expect(summary.totalRevenue, 501 * 158);
          expect(summary.serviceTotal, 501 * 7);
          expect(summary.paymentReceivedTotal, 501 * 110);
          expect(summary.paymentVariance, 501 * 10);
          expect(summary.cashTotal, 501 * 110);
          expect(summary.totalOrders, 501 * 4);
          expect(summary.completedOrders, 501 * 4);
          expect(summary.paidOrders, 501 * 4);
          expect(summary.cancelledItems, 501);
          expect(summary.cancelledAmount, 7);
          expect(summary.missingProofPhotosCount, 501);
          expect(summary.failedEinvoiceJobsCount, 501);
          expect(summary.einvoiceReviewIssues, hasLength(501));
          expect(
            summary.dailyBreakdown.fold<double>(
              0,
              (sum, row) => sum + row.total,
            ),
            summary.totalRevenue,
          );
          expect(report.exportToExcel(), isNotEmpty);
        },
      );

      test(
        'super admin sums complete inputs and includes stores outside explicit assignments',
        () async {
          await seed(501);
          await sql(
            "INSERT INTO photo_objet_sales VALUES ('a0000000-0000-0000-0000-000000009999','$_otherStore','2024-01-01',70,5,1)",
          );
          actor = _superAdmin;
          final report = _AdminReports(client)
            ..setStores([_store, _otherStore]);
          addTearDown(report.dispose);
          await report.setReportRange(DateTime(2024), DateTime(2029, 12, 31));
          expect(report.state.error, isNull);
          // Preserve this screen's existing received-amount basis (110 vs 100 sales).
          expect(report.state.reportSummary!.totalRevenue, 501 * 168 + 65);
          expect(report.state.reportSummary!.rows, hasLength(2));
        },
      );

      test(
        'both reports include the first HCM instant and exclude next midnight',
        () async {
          await sql(
            '''INSERT INTO payments(id,restaurant_id,amount,amount_portion,method,created_at,is_revenue)
        VALUES ('60000000-0000-0000-0000-000000000001','$_store',10,10,'CASH','2026-07-26 17:00:00+00',true),
        ('60000000-0000-0000-0000-000000000002','$_store',20,20,'CASH','2026-07-27 16:59:59.999999+00',true),
        ('60000000-0000-0000-0000-000000000003','$_store',1000,1000,'CASH','2026-07-27 17:00:00+00',true);''',
          );
          final report = ReportNotifier(client: client);
          final admin = _AdminReports(client)..setStores([_store]);
          addTearDown(report.dispose);
          addTearDown(admin.dispose);
          await report.setDateRange(
            DateTime(2026, 7, 27),
            DateTime(2026, 7, 27),
            _store,
          );
          await admin.setReportRange(
            DateTime(2026, 7, 27),
            DateTime(2026, 7, 27),
          );
          expect(report.state.summary!.totalRevenue, 30);
          expect(admin.state.reportSummary!.totalRevenue, 30);
        },
      );

      final edits = {
        'earlier value changed':
            "UPDATE employee_daily_allowances SET meal_allowance_amount=99 WHERE employee_id='$_employee'",
        'earlier row deleted':
            "DELETE FROM employee_daily_allowances WHERE employee_id='$_employee'",
        'backfill before cursor':
            "INSERT INTO employee_daily_allowances VALUES ('41000000-0000-0000-0000-000000009999','$_store','$_employee','2026-07-26',false,1,1)",
      };
      for (final edit in edits.entries) {
        test('rejects mixed supplemental input when ${edit.key}', () async {
          await seed(501);
          beforePage = (source, page) async {
            if (page == 2) await sql(edit.value);
          };
          await expectLater(
            load(FinancialInputSource.allowances),
            throwsA(
              isA<PostgrestException>().having(
                (e) => e.message,
                'message',
                contains('FINANCIAL_INPUT_CHANGED'),
              ),
            ),
          );
        });
      }

      test('detects a changed aggregate value in the invoker view', () async {
        await seed(501);
        beforePage = (source, page) async {
          if (page == 2) {
            await sql(
              "UPDATE photo_objet_sales SET gross_sales=99 WHERE sale_date='2024-01-01'",
            );
          }
        };
        await expectLater(
          load(FinancialInputSource.photoSales),
          throwsA(isA<PostgrestException>()),
        );
      });

      test('scope checks and underlying RLS both apply', () async {
        await seed(1);
        await expectLater(
          load(FinancialInputSource.orders, stores: [_otherStore]),
          throwsA(isA<PostgrestException>()),
        );
        actor = '20000000-0000-0000-0000-000000000002';
        expect(await load(FinancialInputSource.orders), hasLength(1));
        expect(await load(FinancialInputSource.staff), isEmpty);
        expect(await load(FinancialInputSource.allowances), isEmpty);
        actor = '';
        await expectLater(
          load(FinancialInputSource.holidays),
          throwsA(isA<PostgrestException>()),
        );
      });

      test('rejects lost authorization between pages', () async {
        await seed(501);
        beforePage = (source, page) async {
          if (page == 2) actor = '';
        };
        await expectLater(
          load(FinancialInputSource.revenuePayments),
          throwsA(isA<PostgrestException>()),
        );
      });

      for (final corruption in [
        'truncate',
        'duplicate',
        'wrongStore',
        'revision',
        'missingCount',
      ]) {
        test('fails closed for $corruption in the last API page', () async {
          await seed(501);
          overridePage = (source, page, payload) {
            if (page != 2) return payload;
            final rows = payload['rows'] as List;
            switch (corruption) {
              case 'truncate':
                payload['rows'] = [];
              case 'duplicate':
                rows.add(rows.single);
              case 'wrongStore':
                (rows.single as Map)['restaurant_id'] = _otherStore;
              case 'revision':
                payload['revision'] = '0' * 32;
              case 'missingCount':
                payload['total_count'] = null;
            }
            return payload;
          };
          await expectLater(
            load(FinancialInputSource.revenuePayments),
            throwsA(anyOf(isA<Exception>(), isA<StateError>())),
          );
        });
      }

      test(
        'rejects unknown source, unbounded dates, oversized pages and invalid cursors',
        () async {
          final base = <String, dynamic>{
            'p_source': 'orders',
            'p_store_ids': [_store],
            'p_from': '2026-07-27T00:00:00Z',
            'p_to': '2026-07-28T00:00:00Z',
          };
          for (final invalid in [
            {'p_source': 'payments; DROP TABLE orders'},
            {'p_from': null},
            {'p_to': 'infinity'},
            {'p_page_size': 501},
            {'p_cursor': []},
            {
              'p_cursor': ['bad', 'bad'],
              'p_expected_revision': '0' * 32,
            },
          ]) {
            await expectLater(
              client.rpc(
                'get_financial_input_page',
                params: {...base, ...invalid},
              ),
              throwsA(isA<PostgrestException>()),
            );
          }
        },
      );

      test('a failed new report clears prior display and export', () async {
        await seed(1);
        final report = ReportNotifier(client: client);
        final admin = _AdminReports(client)..setStores([_store]);
        addTearDown(report.dispose);
        addTearDown(admin.dispose);
        await report.setDateRange(
          DateTime(2024),
          DateTime(2029, 12, 31),
          _store,
        );
        await admin.setReportRange(DateTime(2024), DateTime(2029, 12, 31));
        actor = '';
        await report.setDateRange(
          DateTime(2026),
          DateTime(2026, 12, 31),
          _store,
        );
        await admin.setReportRange(DateTime(2026), DateTime(2026, 12, 31));
        expect(report.state.summary, isNull);
        expect(report.state.error, isNotNull);
        expect(report.exportToExcel(), isEmpty);
        expect(admin.state.reportSummary, isNull);
        expect(admin.state.error, isNotNull);
      });

      test(
        'multi-store view pages preserve ties and the requested scope',
        () async {
          await seed(251);
          await sql('''INSERT INTO photo_objet_sales
          SELECT ('a1000000-0000-0000-0000-' || lpad(i::text,12,'0'))::uuid,
            '$_otherStore', '2024-01-01'::date+i-1, 70,5,1
          FROM generate_series(1,251) i;''');
          expect(await load(FinancialInputSource.photoSales), hasLength(251));
          actor = _superAdmin;
          expect(
            await load(
              FinancialInputSource.photoSales,
              stores: [_store, _otherStore],
            ),
            hasLength(502),
          );
        },
      );

      test(
        'active and revenue filters exclude non-payroll and non-sales inputs',
        () async {
          await seed(1);
          await sql('''UPDATE store_employees SET is_active=false;
          UPDATE vietnam_public_holidays SET is_active=false;
          UPDATE external_sales SET order_status='cancelled';
          UPDATE order_items SET status='served';''');
          for (final source in [
            FinancialInputSource.staff,
            FinancialInputSource.holidays,
            FinancialInputSource.externalSales,
            FinancialInputSource.cancelledItems,
          ]) {
            expect(await load(source), isEmpty);
          }
          final revenue = await load(FinancialInputSource.revenuePayments);
          final serviceRows = await load(FinancialInputSource.servicePayments);
          expect(revenue.single['amount_portion'], 100);
          expect(serviceRows.single['amount'], 5);
        },
      );

      test(
        'invalidated super admin store selection cannot restore an old report',
        () async {
          await seed(1);
          final report = _AdminReports(client)..setStores([_store]);
          addTearDown(report.dispose);
          final blocked = Completer<void>();
          final release = Completer<void>();
          beforePage = (source, page) async {
            if (source == 'photoSales') {
              blocked.complete();
              await release.future;
            }
          };
          final old = report.setReportRange(
            DateTime(2024),
            DateTime(2029, 12, 31),
          );
          await blocked.future;
          report.selectRestaurant(null);
          release.complete();
          await old;
          expect(report.state.reportSummary, isNull);
          expect(report.state.isLoading, isFalse);
        },
      );

      test('late old report cannot replace a newer date range', () async {
        await seed(1);
        final report = ReportNotifier(client: client);
        addTearDown(report.dispose);
        final blocked = Completer<void>();
        final release = Completer<void>();
        beforePage = (source, page) async {
          if (source == 'revenuePayments' && page == 1) {
            blocked.complete();
            await release.future;
          }
        };
        final old = report.setDateRange(
          DateTime(2024),
          DateTime(2029, 12, 31),
          _store,
        );
        await blocked.future;
        await report.setDateRange(
          DateTime(2030),
          DateTime(2030, 12, 31),
          _store,
        );
        expect(report.state.summary!.totalRevenue, 0);
        release.complete();
        await old;
        expect(report.state.summary!.totalRevenue, 0);
        expect(report.state.startDate, DateTime(2030));
      });
    },
    skip: rpcUrl == null || dbContainer == null
        ? 'Run scripts/test_financial_inputs_postgrest.sh for the disposable real SQL/API fixture.'
        : false,
  );
}
