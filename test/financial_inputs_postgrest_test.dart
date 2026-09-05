import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'helpers/legacy_report_aggregation.dart' show legacyReportSummary;

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/attendance_service.dart';
import 'package:globos_pos_system/core/services/financial_input_service.dart';
import 'package:globos_pos_system/core/services/payroll_service.dart';
import 'package:globos_pos_system/core/services/store_revenue_summary_service.dart';
import 'package:globos_pos_system/features/report/report_provider.dart';
import 'package:globos_pos_system/features/super_admin/super_admin_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

const _store = '10000000-0000-0000-0000-000000000001';
const _otherStore = '10000000-0000-0000-0000-000000000002';
const _admin = '20000000-0000-0000-0000-000000000001';
const _superAdmin = '20000000-0000-0000-0000-000000000003';
const _employee = '30000000-0000-0000-0000-000000000001';

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
      var rejectSummary = false;
      final requests = <String, int>{};
      final requestedScopes = <String, List<List<dynamic>>>{};
      final returnedRows = <String, int>{};
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
      INSERT INTO employee_hourly_pay_rules(employee_id,store_id,hourly_rate,night_multiplier)
      SELECT id,store_id,100,1 FROM store_employees WHERE store_id = '$_store';
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
            final isRules = request.uri.path.endsWith(
              '/get_payroll_hourly_rules',
            );
            final isSummary = request.uri.path.endsWith(
              '/get_store_revenue_summary',
            );
            final isReport = request.uri.path.endsWith(
              '/get_store_report_summary',
            );
            final source = isReport
                ? 'storeReport'
                : isRules
                ? 'hourlyRules'
                : isSummary
                ? 'storeRevenueSummary'
                : isPage
                ? (jsonDecode(body) as Map)['p_source'] as String
                : '';
            final page = isPage || isSummary || isRules || isReport
                ? (requests[source] ?? 0) + 1
                : 0;
            if (isPage || isSummary || isRules || isReport) {
              requests[source] = page;
              final scope = (jsonDecode(body) as Map)['p_store_ids'];
              if (scope is List) {
                requestedScopes.putIfAbsent(source, () => []).add(scope);
              }
              await beforePage?.call(source, page);
            }
            if (isSummary && rejectSummary) {
              request.response.statusCode = 404;
              request.response.headers.contentType = ContentType.json;
              request.response.write(
                jsonEncode({
                  'code': 'PGRST202',
                  'message': 'Summary RPC is not deployed',
                }),
              );
              await request.response.close();
              return;
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
            if ((isPage || isSummary || isRules || isReport) &&
                response.statusCode == 200) {
              final payload = jsonDecode(data) as Map;
              final rows = (payload[isReport ? 'daily' : 'rows']) as List;
              returnedRows.update(
                source,
                (n) => n + rows.length,
                ifAbsent: () => rows.length,
              );
            }
            request.response.write(
              (isPage || isSummary || isRules || isReport) &&
                      response.statusCode == 200 &&
                      overridePage != null
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
        rejectSummary = false;
        requests.clear();
        requestedScopes.clear();
        returnedRows.clear();
        beforePage = null;
        overridePage = null;
        await sql(
          'TRUNCATE attendance_logs, employee_hourly_pay_rules, store_employees, employee_daily_allowances, '
          'vietnam_public_holidays, payments, orders, order_items, external_sales, '
          'meinvoice_jobs, photo_objet_sales;',
        );
      });

      for (final count in [0, 1, 500, 501, 1500]) {
        test('hourly rules batch covers $count employees', () async {
          await seed(count);
          final ids = List.generate(
            count,
            (i) =>
                '30000000-0000-0000-0000-${(i + 1).toString().padLeft(12, '0')}',
          );
          final rules = await AttendanceService(
            client: client,
          ).fetchHourlyPayRules(storeId: _store, employeeIds: [...ids, ...ids]);
          expect(rules.length, count);
          expect(rules.values.every((r) => r?['hourly_rate'] == 100), isTrue);
          expect(requests['hourlyRules'] ?? 0, (count / 500).ceil());
        });
      }
      test('missing rule is explicit; other-store rule cannot leak', () async {
        await seed(1);
        await sql(
          "UPDATE employee_hourly_pay_rules SET store_id = '$_otherStore'",
        );
        final result = await AttendanceService(
          client: client,
        ).fetchHourlyPayRules(storeId: _store, employeeIds: [_employee]);
        expect(result, {_employee: null});
      });
      for (final identity in ['', '20000000-0000-0000-0000-000000000002']) {
        test(
          'hourly rules reject unauthenticated or non-manager $identity',
          () async {
            actor = identity;
            await expectLater(
              AttendanceService(
                client: client,
              ).fetchHourlyPayRules(storeId: _store, employeeIds: [_employee]),
              throwsA(isA<PostgrestException>()),
            );
          },
        );
      }
      test('hourly rules reject unauthorized store', () async {
        await expectLater(
          AttendanceService(
            client: client,
          ).fetchHourlyPayRules(storeId: _otherStore, employeeIds: [_employee]),
          throwsA(isA<PostgrestException>()),
        );
      });
      test('hourly rules respect underlying SELECT grant', () async {
        await sql(
          'REVOKE SELECT ON employee_hourly_pay_rules FROM authenticated',
        );
        try {
          await expectLater(
            AttendanceService(
              client: client,
            ).fetchHourlyPayRules(storeId: _store, employeeIds: [_employee]),
            throwsA(isA<PostgrestException>()),
          );
        } finally {
          await sql(
            'GRANT SELECT ON employee_hourly_pay_rules TO authenticated',
          );
        }
      });
      test(
        'hourly rules do not return partial results after batch failure',
        () async {
          await seed(501);
          beforePage = (source, page) async {
            if (source == 'hourlyRules' && page == 2) actor = '';
          };
          final ids = List.generate(
            501,
            (i) =>
                '30000000-0000-0000-0000-${(i + 1).toString().padLeft(12, '0')}',
          );
          await expectLater(
            AttendanceService(
              client: client,
            ).fetchHourlyPayRules(storeId: _store, employeeIds: ids),
            throwsA(isA<PostgrestException>()),
          );
        },
      );
      for (final invalid in [
        'missing',
        'duplicate',
        'scope',
        'rule',
        'version',
      ]) {
        test('hourly rules reject malformed $invalid response', () async {
          overridePage = (source, page, payload) {
            if (source != 'hourlyRules') return payload;
            switch (invalid) {
              case 'missing':
                payload['rows'] = [];
                break;
              case 'duplicate':
                (payload['rows'] as List).add((payload['rows'] as List).first);
                break;
              case 'scope':
                payload['store_id'] = _otherStore;
                break;
              case 'rule':
                ((payload['rows'] as List).first as Map)['rule'] = false;
                break;
              case 'version':
                payload['version'] = 2;
                break;
            }
            return payload;
          };
          await expectLater(
            AttendanceService(
              client: client,
            ).fetchHourlyPayRules(storeId: _store, employeeIds: [_employee]),
            throwsA(isA<FormatException>()),
          );
        });
      }

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
          final source = AttendanceService(client: client);
          final payroll = await PayrollService(attendanceSource: source)
              .calculatePayroll(
                storeId: _store,
                periodStart: DateTime(2026, 7, 27),
                periodEnd: DateTime(2026, 7, 27),
              );
          expect(payroll, hasLength(502));
          expect(requests['hourlyRules'], 2);
          expect(returnedRows['hourlyRules'], 502);
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
        'detailed report matches frozen legacy calculation over mixed inputs',
        () async {
          await seed(1500);
          await sql("""
          UPDATE payments SET amount_portion = CASE WHEN id::text LIKE '600%' THEN
            CASE (right(id::text,4)::int % 4) WHEN 0 THEN NULL WHEN 1 THEN 0 WHEN 2 THEN -3.25 ELSE 41.33 END
            ELSE amount_portion END,
            method = (ARRAY['cash','card','credit_card','ATM','BANKTRANSFER','pay','MOMO','service','',' custom '])[1+right(id::text,4)::int%10],
            proof_photo_url = CASE WHEN right(id::text,4)::int%2=0 AND right(id::text,4)::int%10<>8 THEN 'proof' ELSE '   ' END;
          UPDATE orders SET sales_channel = CASE WHEN right(id::text,4)::int%3=0 THEN 'DeLiVeRy' ELSE NULL END,
            status = (ARRAY['completed','cancelled','confirmed'])[1+right(id::text,4)::int%3];
          UPDATE photo_objet_sales SET service_amount = CASE WHEN right(id::text,4)::int%3=0 THEN 70 ELSE 2 END;
          UPDATE meinvoice_jobs SET status = CASE WHEN right(id::text,4)::int%2=0 THEN 'issued' ELSE 'manual_action_required' END,
            error_message = ' ', manual_action_type = ' buyer_review ';
        """);
          final legacy = legacyReportSummary(
            requestedStart: DateTime(2024),
            paymentsRevenueResponse: await load(
              FinancialInputSource.revenuePayments,
            ),
            externalSalesResponse: await load(
              FinancialInputSource.externalSales,
            ),
            photoObjetSalesResponse: await load(
              FinancialInputSource.photoSales,
            ),
            servicePaymentsResponse: await load(
              FinancialInputSource.servicePayments,
            ),
            ordersResponse: await load(FinancialInputSource.orders),
            cancelledAmountResponse: 7,
            cancelledItemsResponse: await load(
              FinancialInputSource.cancelledItems,
            ),
            einvoiceJobsResponse: await load(FinancialInputSource.einvoiceJobs),
          );
          requests.clear();
          final report = ReportNotifier(client: client);
          addTearDown(report.dispose);
          await report.setDateRange(
            DateTime(2024),
            DateTime(2029, 12, 31),
            _store,
          );
          expect(report.state.error, isNull);
          expect(requests, {'storeReport': 1});
          final actual = report.state.summary!;
          List<num> totals(ReportSummary s) => [
            s.dineInRevenue,
            s.deliveryRevenue,
            s.serviceTotal,
            s.cancelledAmount,
            s.totalOrders,
            s.completedOrders,
            s.paidOrders,
            s.openOrders,
            s.cancelledOrders,
            s.cancelledItems,
            s.cashTotal,
            s.cardTotal,
            s.bankTransferTotal,
            s.payTotal,
            s.paymentVariance,
            s.proofCompletePercent,
            s.missingProofPhotosCount,
            s.failedEinvoiceJobsCount,
          ];
          final expected = totals(legacy);
          final received = totals(actual);
          for (var i = 0; i < expected.length; i++) {
            expect(
              received[i],
              closeTo(expected[i], 0.00001),
              reason: 'field $i',
            );
          }
          expect(actual.dailyBreakdown.length, legacy.dailyBreakdown.length);
          for (var i = 0; i < legacy.dailyBreakdown.length; i++) {
            final a = actual.dailyBreakdown[i], b = legacy.dailyBreakdown[i];
            expect(a.date, b.date);
            expect(a.total, closeTo(b.total, 0.00001));
            expect(a.teamCount, b.teamCount);
            expect(a.paymentVariance, closeTo(b.paymentVariance, 0.00001));
          }
          for (var i = 0; i < legacy.hourlyBreakdown.length; i++) {
            expect(
              actual.hourlyBreakdown[i].hour,
              legacy.hourlyBreakdown[i].hour,
            );
            expect(
              actual.hourlyBreakdown[i].amount,
              closeTo(legacy.hourlyBreakdown[i].amount, 0.00001),
            );
          }
          expect(
            actual.paymentMethodBreakdown.length,
            legacy.paymentMethodBreakdown.length,
          );
          for (var i = 0; i < legacy.paymentMethodBreakdown.length; i++) {
            final a = actual.paymentMethodBreakdown[i],
                b = legacy.paymentMethodBreakdown[i];
            expect(a.method, b.method);
            expect(a.count, b.count);
            expect(a.totalAmount, closeTo(b.totalAmount, 0.00001));
            expect(a.proofCompletePct, closeTo(b.proofCompletePct, 0.00001));
          }
          expect(
            actual.missingProofIssues.map((r) => r.paymentId),
            legacy.missingProofIssues.map((r) => r.paymentId),
          );
          expect(
            actual.missingProofIssues.map(
              (r) => [r.method, r.amount, r.createdAt],
            ),
            legacy.missingProofIssues.map(
              (r) => [r.method, r.amount, r.createdAt],
            ),
          );
          expect(
            actual.einvoiceReviewIssues.map((r) => r.paymentId),
            legacy.einvoiceReviewIssues.map((r) => r.paymentId),
          );
          expect(
            actual.einvoiceReviewIssues.map((r) => r.detail),
            legacy.einvoiceReviewIssues.map((r) => r.detail),
          );
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
          // Revenue follows the sales allocation; received cash is a separate metric.
          expect(report.state.reportSummary!.totalRevenue, 501 * 158 + 65);
          expect(report.state.reportSummary!.rows, hasLength(2));
        },
      );

      test('live dashboard update aggregates only its changed store', () async {
        await seed(1);
        actor = _superAdmin;
        await sql(
          "INSERT INTO payments VALUES ('60000000-0000-0000-0000-000000009999','$_otherStore',NULL,700,700,'CASH','2026-07-27',false,NULL,true)",
        );
        final admin = _AdminReports(client)..setStores([_store, _otherStore]);
        addTearDown(admin.dispose);
        await admin.setReportRange(DateTime(2024), DateTime(2029, 12, 31));
        expect(admin.state.reportSummary!.totalRevenue, 858);
        requests.clear();
        requestedScopes.clear();
        await sql(
          "UPDATE payments SET amount_portion=250 WHERE restaurant_id='$_store' AND is_revenue=true",
        );
        await admin.refreshReportsForStore(_store);
        expect(requests, {'storeRevenueSummary': 1});
        expect(requestedScopes['storeRevenueSummary'], [
          [_store],
        ]);
        expect(admin.state.reportSummary!.totalRevenue, 1008);
        expect(
          admin.state.reportSummary!.rows
              .singleWhere((r) => r.storeId == _otherStore)
              .total,
          700,
        );
      });
      test('live dashboard update cannot overwrite a new date scope', () async {
        await seed(1);
        final admin = _AdminReports(client)..setStores([_store]);
        addTearDown(admin.dispose);
        await admin.setReportRange(DateTime(2024), DateTime(2029, 12, 31));
        requests.clear();
        final started = Completer<void>(), release = Completer<void>();
        beforePage = (source, page) async {
          if (source == 'storeRevenueSummary' && page == 1) {
            started.complete();
            await release.future;
          }
        };
        final old = admin.refreshReportsForStore(_store);
        await started.future;
        await admin.setReportRange(DateTime(2030), DateTime(2030, 12, 31));
        release.complete();
        await old;
        expect(admin.state.reportSummary!.totalRevenue, 0);
      });

      test('global report uses one aggregate request for 100 stores', () async {
        await seed(501);
        actor = _superAdmin;
        final stores = [
          for (var i = 1; i <= 100; i++)
            '10000000-0000-0000-0000-${i.toString().padLeft(12, '0')}',
        ];
        final report = _AdminReports(client)..setStores(stores);
        addTearDown(report.dispose);
        await report.setReportRange(DateTime(2024), DateTime(2029, 12, 31));
        expect(report.state.error, isNull);
        expect(report.state.reportSummary!.rows, hasLength(100));
        expect(report.state.reportSummary!.totalRevenue, 501 * 158);
        expect(requests.values.fold<int>(0, (a, b) => a + b), 1);
        expect(requests['storeRevenueSummary'], 1);
        expect(returnedRows, {'storeRevenueSummary': 100});
      });

      Future<Map<String, StoreRevenueTotals>> aggregate({
        List<String> stores = const [_store],
      }) => StoreRevenueSummaryService(client).fetch(
        storeIds: stores,
        fromDate: DateTime(2024),
        toDate: DateTime(2029, 12, 31),
      );

      for (final count in [1, 10, 50, 500]) {
        test(
          'aggregate returns all $count zero-activity stores despite the API row cap',
          () async {
            actor = _superAdmin;
            final stores = [
              for (var i = 1; i <= count; i++)
                '10000000-0000-0000-0000-${i.toString().padLeft(12, '0')}',
            ];
            final totals = await aggregate(stores: stores);
            expect(totals.keys.toSet(), stores.toSet());
            expect(
              totals.values.every((v) => v.dineIn == 0 && v.delivery == 0),
              isTrue,
            );
            expect(requests, {'storeRevenueSummary': 1});
            expect(returnedRows, {'storeRevenueSummary': count});
          },
        );
      }

      test(
        'aggregate matches complete legacy arithmetic across 1500 rows and mixed stores',
        () async {
          await seed(1500);
          await sql("""
          UPDATE payments SET amount=123.45, amount_portion=CASE
            WHEN right(id::text,12)::bigint % 6 = 0 THEN NULL
            WHEN right(id::text,12)::bigint % 6 = 1 THEN 0
            WHEN right(id::text,12)::bigint % 6 = 2 THEN -5.25 ELSE 100.37 END;
          UPDATE payments SET is_revenue=false WHERE right(id::text,12)::bigint % 7 = 0;
          UPDATE payments SET is_revenue=NULL WHERE right(id::text,12)::bigint % 11 = 0;
          UPDATE payments SET order_id=NULL WHERE right(id::text,12)::bigint % 13 = 0;
          UPDATE orders SET sales_channel=CASE right(id::text,12)::bigint % 5
            WHEN 0 THEN 'DELIVERY' WHEN 1 THEN ' delivery ' WHEN 2 THEN NULL
            WHEN 3 THEN 'takeaway' ELSE 'dine_in' END;
          UPDATE external_sales SET net_amount=CASE right(id::text,12)::bigint % 3
            WHEN 0 THEN NULL WHEN 1 THEN -2.15 ELSE 8.27 END;
          UPDATE external_sales SET order_status='cancelled' WHERE right(id::text,12)::bigint % 7 = 0;
          UPDATE external_sales SET is_revenue=false WHERE right(id::text,12)::bigint % 11 = 0;
          INSERT INTO photo_objet_sales VALUES
            ('a1000000-0000-0000-0000-000000000001','$_store','2024-01-01',5,300,1),
            ('a1000000-0000-0000-0000-000000000002','$_store','2024-01-02',500,5,1),
            ('a1000000-0000-0000-0000-000000000003','$_otherStore','2024-01-01',70,5,1);
          INSERT INTO payments(id,restaurant_id,amount,amount_portion,created_at,is_revenue)
            VALUES ('62000000-0000-0000-0000-000000000001','$_otherStore',19.9,NULL,'2026-07-27',true);
          INSERT INTO external_sales VALUES
            ('71000000-0000-0000-0000-000000000001','$_otherStore',13.2,'2026-07-27',true,'completed');
        """);
          actor = _superAdmin;
          const stores = [_store, _otherStore];
          final expected = <String, StoreRevenueTotals>{
            for (final id in stores) id: (dineIn: 0, delivery: 0),
          };
          for (final row in await load(
            FinancialInputSource.revenuePayments,
            stores: stores,
          )) {
            final id = row['restaurant_id'] as String;
            final prior = expected[id]!;
            final amount = revenuePaymentSalesAmount(row);
            final delivery =
                ((row['orders'] as Map?)?['sales_channel']?.toString() ?? '')
                    .toLowerCase() ==
                'delivery';
            expected[id] = (
              dineIn: prior.dineIn + (delivery ? 0 : amount),
              delivery: prior.delivery + (delivery ? amount : 0),
            );
          }
          for (final row in await load(
            FinancialInputSource.externalSales,
            stores: stores,
          )) {
            final id = row['restaurant_id'] as String;
            final prior = expected[id]!;
            expected[id] = (
              dineIn: prior.dineIn,
              delivery:
                  prior.delivery +
                  ((row['net_amount'] as num?)?.toDouble() ?? 0),
            );
          }
          final photo = aggregateSuperAdminPhotoObjetSalesByStore(
            await load(FinancialInputSource.photoSales, stores: stores),
          );
          for (final id in stores) {
            final prior = expected[id]!;
            expected[id] = (
              dineIn: prior.dineIn + (photo[id] ?? 0),
              delivery: prior.delivery,
            );
          }
          requests.clear();
          returnedRows.clear();
          final actual = await aggregate(stores: stores);
          for (final id in stores) {
            expect(actual[id]!.dineIn, closeTo(expected[id]!.dineIn, 0.000001));
            expect(
              actual[id]!.delivery,
              closeTo(expected[id]!.delivery, 0.000001),
            );
          }
          expect(requests, {'storeRevenueSummary': 1});
          expect(returnedRows, {'storeRevenueSummary': 2});
        },
      );

      test(
        'selected store loads only its aggregate and empty selection avoids RPC',
        () async {
          await seed(1);
          actor = _superAdmin;
          final report = _AdminReports(client)
            ..setStores([_store, _otherStore]);
          addTearDown(report.dispose);
          await report.setReportRange(DateTime(2024), DateTime(2029, 12, 31));
          requests.clear();
          await report.loadAllReports(selectedRestaurantId: _otherStore);
          expect(report.state.reportSummary!.rows.single.storeId, _otherStore);
          expect(report.state.reportSummary!.totalRevenue, 0);
          expect(requests, {'storeRevenueSummary': 1});
          report.setStores([]);
          requests.clear();
          await report.loadAllReports();
          expect(report.state.reportSummary!.rows, isEmpty);
          expect(requests, isEmpty);
        },
      );

      test(
        'aggregate rejects unauthorized and mixed store scopes atomically',
        () async {
          await seed(1);
          for (final stores in [
            [_otherStore],
            [_store, _otherStore],
          ]) {
            await expectLater(
              aggregate(stores: stores),
              throwsA(isA<PostgrestException>()),
            );
          }
          actor = '';
          await expectLater(aggregate(), throwsA(isA<PostgrestException>()));
          actor = _superAdmin;
          expect(
            (await aggregate(stores: [_store, _otherStore])).keys,
            hasLength(2),
          );
        },
      );

      test('aggregate retains underlying table RLS and SELECT grants', () async {
        await seed(1);
        await sql('ALTER POLICY payments_read ON payments USING (false);');
        try {
          final actual = (await aggregate())[_store]!;
          expect(actual.dineIn, 48);
          expect(actual.delivery, 10);
        } finally {
          await sql(
            'ALTER POLICY payments_read ON payments USING (public.fixture_can_read(restaurant_id));',
          );
        }
        await sql('REVOKE SELECT ON payments FROM authenticated;');
        try {
          await expectLater(aggregate(), throwsA(isA<PostgrestException>()));
        } finally {
          await sql('GRANT SELECT ON payments TO authenticated;');
        }
      });

      test(
        'aggregate rejects invalid dates, duplicate/null stores and oversized scopes',
        () async {
          actor = _superAdmin;
          final params = <String, dynamic>{
            'p_store_ids': [_store],
            'p_from_date': '2024-01-01',
            'p_to_date': '2029-12-31',
          };
          for (final invalid in [
            {'p_store_ids': null},
            {'p_store_ids': []},
            {
              'p_store_ids': [_store, _store],
            },
            {
              'p_store_ids': [_store, null],
            },
            {'p_from_date': null},
            {'p_to_date': 'infinity'},
            {'p_to_date': '2023-12-31'},
            {
              'p_store_ids': [
                for (var i = 1; i <= 501; i++)
                  '10000000-0000-0000-0000-${i.toString().padLeft(12, '0')}',
              ],
            },
          ]) {
            await expectLater(
              client.rpc(
                'get_store_revenue_summary',
                params: {...params, ...invalid},
              ),
              throwsA(isA<PostgrestException>()),
            );
          }
        },
      );

      for (final corruption in [
        'truncate',
        'duplicate',
        'wrongStore',
        'fromDate',
        'toDate',
        'missingCount',
        'version',
        'nullAmount',
        'nanAmount',
        'infiniteAmount',
      ]) {
        test(
          'aggregate fails closed and clears old report for $corruption',
          () async {
            await seed(1);
            actor = _superAdmin;
            final report = _AdminReports(client)
              ..setStores([_store, _otherStore]);
            addTearDown(report.dispose);
            await report.setReportRange(DateTime(2024), DateTime(2029, 12, 31));
            expect(report.state.reportSummary, isNotNull);
            overridePage = (source, page, payload) {
              if (source != 'storeRevenueSummary') return payload;
              final rows = payload['rows'] as List;
              switch (corruption) {
                case 'truncate':
                  rows.removeLast();
                case 'duplicate':
                  rows[1] = rows.first;
                case 'wrongStore':
                  (rows.first as Map)['store_id'] = 'foreign';
                case 'fromDate':
                  payload['from_date'] = '2030-01-01';
                case 'toDate':
                  payload['to_date'] = '2030-01-01';
                case 'missingCount':
                  payload.remove('store_count');
                case 'version':
                  payload['version'] = 999;
                case 'nullAmount':
                  (rows.first as Map)['dine_in'] = null;
                case 'nanAmount':
                  (rows.first as Map)['dine_in'] = 'NaN';
                case 'infiniteAmount':
                  (rows.first as Map)['delivery'] = 'Infinity';
              }
              return payload;
            };
            requests.clear();
            await report.loadAllReports();
            expect(report.state.reportSummary, isNull);
            expect(report.state.error, isNotNull);
            expect(requests, {'storeRevenueSummary': 1});
          },
        );
      }

      for (final failOld in [false, true]) {
        test(
          'late aggregate ${failOld ? 'failure' : 'success'} cannot replace a new period',
          () async {
            await seed(1);
            final report = _AdminReports(client)..setStores([_store]);
            addTearDown(report.dispose);
            final blocked = Completer<void>();
            final release = Completer<void>();
            beforePage = (source, page) async {
              if (source == 'storeRevenueSummary' && page == 1) {
                blocked.complete();
                await release.future;
              }
            };
            if (failOld) {
              overridePage = (source, page, payload) {
                if (source == 'storeRevenueSummary' && page == 1) {
                  payload['rows'] = [];
                }
                return payload;
              };
            }
            final old = report.setReportRange(
              DateTime(2024),
              DateTime(2029, 12, 31),
            );
            await blocked.future;
            await report.setReportRange(DateTime(2030), DateTime(2030, 12, 31));
            release.complete();
            await old;
            expect(report.state.reportSummary!.totalRevenue, 0);
            expect(report.state.error, isNull);
            expect(report.state.reportStart, DateTime(2030));
          },
        );
      }

      test(
        'missing aggregate RPC clears old totals without a raw-data fallback',
        () async {
          await seed(1);
          final report = _AdminReports(client)..setStores([_store]);
          addTearDown(report.dispose);
          await report.setReportRange(DateTime(2024), DateTime(2029, 12, 31));
          expect(report.state.reportSummary, isNotNull);
          rejectSummary = true;
          requests.clear();
          await report.loadAllReports();
          expect(report.state.reportSummary, isNull);
          expect(report.state.error, contains('PGRST202'));
          expect(requests, {'storeRevenueSummary': 1});
        },
      );

      test(
        'disposing during an aggregate prevents late report publication',
        () async {
          final report = _AdminReports(client)..setStores([_store]);
          final blocked = Completer<void>();
          final release = Completer<void>();
          beforePage = (source, page) async {
            if (source == 'storeRevenueSummary') {
              blocked.complete();
              await release.future;
            }
          };
          final loading = report.setReportRange(
            DateTime(2024),
            DateTime(2029, 12, 31),
          );
          await blocked.future;
          report.dispose();
          release.complete();
          await loading;
          expect(requests, {'storeRevenueSummary': 1});
        },
      );

      test(
        'aggregate keeps one statement snapshot during concurrent source updates',
        () async {
          await seed(1);
          // Pause the Photo Objet branch after the request's statement snapshot
          // exists, commit changes to all three sources, then let it finish.
          await sql(r"""
          ALTER VIEW public.v_photo_objet_daily_summary RENAME TO fixture_photo_original;
          CREATE FUNCTION public.fixture_report_pause() RETURNS boolean LANGUAGE plpgsql VOLATILE AS $$
          BEGIN PERFORM pg_advisory_xact_lock(825910); RETURN true; END $$;
          CREATE VIEW public.v_photo_objet_daily_summary WITH (security_invoker=true) AS
            SELECT * FROM public.fixture_photo_original WHERE public.fixture_report_pause();
          GRANT SELECT ON public.v_photo_objet_daily_summary TO authenticated;
        """);
          final holder = await Process.start('docker', [
            'exec',
            '-i',
            dbContainer!,
            'psql',
            '-X',
            '-q',
            '-v',
            'ON_ERROR_STOP=1',
            '-U',
            'postgres',
            '-d',
            'payroll_test',
          ]);
          final stdoutDone = holder.stdout.drain<void>();
          final stderrDone = holder.stderr.drain<void>();
          holder.stdin.writeln('BEGIN; SELECT pg_advisory_xact_lock(825910);');
          await holder.stdin.flush();
          Future<void> waitForLock(bool granted) => sql('''
          DO \$\$ BEGIN
            FOR attempt IN 1..250 LOOP
              IF EXISTS (SELECT 1 FROM pg_locks WHERE locktype='advisory' AND objid=825910 AND granted=$granted) THEN RETURN; END IF;
              PERFORM pg_sleep(0.02);
            END LOOP;
            RAISE EXCEPTION 'REPORT_FIXTURE_LOCK_TIMEOUT';
          END \$\$;
        ''');
          var released = false;
          try {
            await waitForLock(true);
            final reading = aggregate();
            await waitForLock(false);
            await sql(
              'UPDATE payments SET amount_portion=900 WHERE is_revenue=true; '
              'UPDATE external_sales SET net_amount=90; UPDATE photo_objet_sales SET gross_sales=500;',
            );
            holder.stdin.writeln('COMMIT;');
            await holder.stdin.close();
            await holder.exitCode;
            released = true;
            final before = (await reading)[_store]!;
            expect(before, (dineIn: 148.0, delivery: 10.0));
            final after = (await aggregate())[_store]!;
            expect(after, (dineIn: 1398.0, delivery: 90.0));
          } finally {
            if (!released) {
              // Closing psql releases/rolls back the fixture transaction on failure.
              await holder.stdin.close();
              await holder.exitCode;
            }
            await Future.wait([stdoutDone, stderrDone]);
            await sql(
              'DROP VIEW public.v_photo_objet_daily_summary; '
              'ALTER VIEW public.fixture_photo_original RENAME TO v_photo_objet_daily_summary; '
              'DROP FUNCTION public.fixture_report_pause();',
            );
          }
        },
      );

      test('POS delivery appears in headline totals beyond one page', () async {
        await seed(501);
        await sql('''UPDATE orders SET sales_channel='delivery';
          TRUNCATE external_sales, photo_objet_sales;''');
        final report = ReportNotifier(client: client);
        addTearDown(report.dispose);
        await report.setDateRange(
          DateTime(2026, 7, 27),
          DateTime(2026, 7, 27),
          _store,
        );
        expect(report.state.error, isNull);
        final summary = report.state.summary!;
        expect(summary.dineInRevenue, 0);
        expect(summary.deliveryRevenue, 50100);
        expect(summary.totalRevenue, 50100);
        expect(summary.dailyBreakdown.single.delivery, 50100);
        expect(summary.hourlyBreakdown.single.amount, 50100);
        expect(summary.paymentReceivedTotal, 55110);
        expect(summary.paymentVariance, 5010);
        expect(summary.serviceTotal, 2505);
        expect(summary.paidOrders, 501);
      });

      test(
        'store, global and Excel sales reconcile across channels and payment splits',
        () async {
          await sql('''
          INSERT INTO orders VALUES
            ('50000000-0000-0000-0000-000000000001','$_store','completed','dine_in','2026-07-27 02:00:00+00'),
            ('50000000-0000-0000-0000-000000000002','$_store','completed','delivery','2026-07-28 02:00:00+00'),
            ('50000000-0000-0000-0000-000000000003','$_store','completed','takeaway','2026-07-27 02:00:00+00');
          INSERT INTO payments(id,restaurant_id,order_id,amount,amount_portion,method,created_at,is_revenue)
          VALUES
            ('60000000-0000-0000-0000-000000000001','$_store','50000000-0000-0000-0000-000000000001',110,100,'CASH','2026-07-27 02:00:00+00',true),
            ('60000000-0000-0000-0000-000000000002','$_store','50000000-0000-0000-0000-000000000001',45,50,'BANKTRANSFER','2026-07-27 02:00:00+00',true),
            ('60000000-0000-0000-0000-000000000003','$_store','50000000-0000-0000-0000-000000000002',220,200,'CASH','2026-07-28 02:00:00+00',true),
            ('60000000-0000-0000-0000-000000000004','$_store','50000000-0000-0000-0000-000000000002',75,NULL,'BANKTRANSFER','2026-07-28 02:00:00+00',true),
            ('60000000-0000-0000-0000-000000000005','$_store','50000000-0000-0000-0000-000000000003',15,0,'CASH','2026-07-27 02:00:00+00',true),
            ('60000000-0000-0000-0000-000000000006','$_store','50000000-0000-0000-0000-000000000003',12,NULL,'CARD','2026-07-27 02:00:00+00',true),
            ('60000000-0000-0000-0000-000000000007','$_store',NULL,8,NULL,'OTHER','2026-07-27 02:00:00+00',true),
            ('61000000-0000-0000-0000-000000000001','$_store',NULL,9,NULL,'CASH','2026-07-27 02:00:00+00',false);
          INSERT INTO external_sales VALUES
            ('70000000-0000-0000-0000-000000000001','$_store',30,'2026-07-27 02:00:00+00',true,'completed'),
            ('70000000-0000-0000-0000-000000000002','$_store',999,'2026-07-27 02:00:00+00',true,'pending'),
            ('70000000-0000-0000-0000-000000000003','$_store',999,'2026-07-27 02:00:00+00',false,'completed');
          INSERT INTO photo_objet_sales VALUES
            ('a0000000-0000-0000-0000-000000000001','$_store','2026-07-27',50,2,2);
        ''');
          final report = ReportNotifier(client: client);
          final global = _AdminReports(client)..setStores([_store]);
          addTearDown(report.dispose);
          addTearDown(global.dispose);
          await report.setDateRange(
            DateTime(2026, 7, 27),
            DateTime(2026, 7, 28),
            _store,
          );
          await global.setReportRange(
            DateTime(2026, 7, 27),
            DateTime(2026, 7, 28),
          );
          expect(report.state.error, isNull);
          expect(global.state.error, isNull);
          final summary = report.state.summary!;
          expect(summary.dineInRevenue, 218);
          expect(summary.deliveryRevenue, 305);
          expect(summary.totalRevenue, 523);
          expect(summary.paymentReceivedTotal, 485);
          expect(summary.paymentVariance, 40);
          expect(summary.cashTotal, 345);
          expect(summary.bankTransferTotal, 120);
          expect(summary.cardTotal, 12);
          expect(summary.payTotal, 8);
          expect(summary.serviceTotal, 11);
          expect(summary.totalOrders, 6);
          expect(summary.paidOrders, 7);
          expect(summary.dailyBreakdown.map((day) => day.total), [248, 275]);
          expect(
            summary.dailyBreakdown.fold<double>(
              0,
              (sum, day) => sum + day.total,
            ),
            summary.totalRevenue,
          );
          // The hourly chart intentionally excludes Photo Objet daily-only input.
          expect(
            summary.hourlyBreakdown.fold<double>(
              0,
              (sum, hour) => sum + hour.amount,
            ),
            475,
          );
          final globalSummary = global.state.reportSummary!;
          expect(globalSummary.totalRevenue, summary.totalRevenue);
          expect(globalSummary.dineInRevenue, summary.dineInRevenue);
          expect(globalSummary.deliveryRevenue, summary.deliveryRevenue);
          expect(globalSummary.rows.single.total, 523);

          final sheet = Excel.decodeBytes(
            report.exportToExcel(),
          ).tables['Sales Report']!;
          double valueFor(String label) => double.parse(
            sheet.rows
                .singleWhere((row) => row.first?.value.toString() == label)[1]!
                .value
                .toString(),
          );
          expect(valueFor('Store Sales Revenue'), 218);
          expect(valueFor('Delivery Sales Revenue'), 305);
          expect(valueFor('Net Sales Revenue'), 523);
          expect(valueFor('Payment Received Total'), 485);
          expect(valueFor('Payment Variance'), 40);
          final totalRow = sheet.rows.singleWhere(
            (row) => row.first?.value.toString() == 'Total',
          );
          expect(double.parse(totalRow[2]!.value.toString()), 305);
          expect(double.parse(totalRow[3]!.value.toString()), 523);
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
            if (source == 'storeRevenueSummary') {
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
          if (source == 'storeReport' && page == 1) {
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
