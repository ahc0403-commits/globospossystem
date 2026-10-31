import 'dart:async';
import 'dart:io';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:globos_pos_system/l10n/app_localizations.dart';
import 'package:globos_pos_system/features/super_admin/legal_entity_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:globos_pos_system/core/utils/deadline_http_client.dart';
import 'package:globos_pos_system/core/services/payment_service.dart';
import 'package:globos_pos_system/core/services/qc_service.dart';
import 'package:globos_pos_system/features/payment/payment_provider.dart';
import 'package:globos_pos_system/features/qc/qc_provider.dart';
import 'package:globos_pos_system/features/emergency_fulfillment/kds_realtime_sync.dart';

class _Qc extends QcService {
  final requests = <String, Completer<List<Map<String, dynamic>>>>{};
  @override
  Future<List<Map<String, dynamic>>> fetchTemplates(String storeId) =>
      (requests[storeId] = Completer<List<Map<String, dynamic>>>()).future;
}

class _Payments extends PaymentService {
  @override
  Future<Map<String, dynamic>> processPayment({
    required String orderId,
    required String storeId,
    required double amount,
    required String method,
  }) async => {'id': 'committed'};
}

class _Cashier extends PaymentNotifier {
  _Cashier() : super(payments: _Payments());
  final refresh = Completer<void>();
  @override
  Future<void> loadOrders(String storeId) => refresh.future;
}

class _CashierReads extends PaymentNotifier {
  _CashierReads(SupabaseClient client)
    : super(client: client, payments: _Payments());
  @override
  Future<void> subscribeRealtime(String storeId) async {}
}

class _AbortTransport extends http.BaseClient {
  final started = Completer<void>();
  bool closed = false;
  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    started.complete();
    await (request as http.AbortableStreamedRequest).abortTrigger;
    throw http.RequestAbortedException(request.url);
  }

  @override
  void close() {
    closed = true;
  }
}

void main() {
  test(
    'a pre-commit read failure cannot overwrite confirmed payment',
    () async {
      final firstStarted = Completer<void>();
      final secondStarted = Completer<void>();
      final first = Completer<void>();
      final second = Completer<void>();
      var reads = 0;
      final seen = <String>[];
      final client = SupabaseClient(
        'http://fixture.invalid',
        'fixture',
        httpClient: MockClient((request) async {
          seen.add(request.url.toString());
          if (request.url.path.endsWith('/restaurants')) {
            return http.Response(
              jsonEncode({'vat_pricing_mode': 'inclusive', 'brands': {}}),
              200,
              headers: {'content-type': 'application/json'},
              request: request,
            );
          }
          if (request.url.path.endsWith('/orders') &&
              request.url.queryParameters['status'] == 'eq.serving') {
            reads++;
            if (reads == 1) {
              firstStarted.complete();
              await first.future;
              return http.Response(
                '{"message":"stale read failed","code":"P0001"}',
                400,
                headers: {'content-type': 'application/json'},
                request: request,
              );
            }
            secondStarted.complete();
            await second.future;
          }
          return http.Response(
            '[]',
            200,
            headers: {'content-type': 'application/json'},
            request: request,
          );
        }),
      );
      final cashier = _CashierReads(client);
      final refresh = cashier.loadOrders('store');
      await firstStarted.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () {
          // ignore: invalid_use_of_protected_member
          throw StateError('first read missing: $seen; ${cashier.state.error}');
        },
      );
      expect(
        (await cashier.processPayment('store', 'order', 100, 'CASH'))?['id'],
        'committed',
      );
      first.complete();
      await secondStarted.future.timeout(
        const Duration(seconds: 1),
        onTimeout: () {
          // ignore: invalid_use_of_protected_member
          throw StateError('follow-up missing: $seen; ${cashier.state.error}');
        },
      );
      // ignore: invalid_use_of_protected_member
      expect(cashier.state.error, isNull);
      // ignore: invalid_use_of_protected_member
      expect(cashier.state.paymentSuccess, isTrue);
      cashier.dispose();
      second.complete();
      await refresh;
      await client.dispose();
    },
  );

  testWidgets('legal entity registration retries retain identity in ko en vi', (
    tester,
  ) async {
    for (final locale in ['ko', 'en', 'vi']) {
      final calls = <Map<String, dynamic>>[];
      Map<String, dynamic>? saved;
      await tester.pumpWidget(
        MaterialApp(
          locale: Locale(locale),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                onPressed: () async {
                  saved = await showLegalEntityEditor(
                    context,
                    register: (values) async {
                      calls.add(Map.of(values));
                      if (calls.length == 1) {
                        throw TimeoutException('acknowledgement lost');
                      }
                      return {'id': values['p_tax_entity_id']};
                    },
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('Open'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).at(0), 'New entity');
      await tester.enterText(find.byType(TextField).at(1), '0312345678');
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      await tester.tap(find.byType(FilledButton));
      await tester.pumpAndSettle();
      expect(calls, hasLength(2));
      expect(calls[0], calls[1]);
      expect(saved?['id'], calls[0]['p_tax_entity_id']);
      expect(find.byType(AlertDialog), findsNothing);
    }
  });

  test(
    'disposing a read owner aborts I/O without closing shared Auth',
    () async {
      final inner = _AbortTransport();
      final lifetime = RequestLifetime();
      final client = DeadlineHttpClient(
        inner,
        DateTime.now().add(const Duration(minutes: 1)),
      );
      lifetime.add(client);
      final request = client.get(Uri.parse('http://fixture.invalid'));
      await inner.started.future;
      lifetime.dispose();
      await expectLater(request, throwsA(isA<TimeoutException>()));
      expect(inner.closed, isFalse);
      inner.close();
    },
  );
  test(
    'committed payment returns while its follow-up read is still pending',
    () async {
      final cashier = _Cashier();
      final result = await cashier
          .processPayment('store', 'order', 100, 'CASH')
          .timeout(const Duration(seconds: 1));
      expect(result?['id'], 'committed');
      // ignore: invalid_use_of_protected_member
      expect(cashier.state.paymentSuccess, isTrue);
      cashier.refresh.complete();
      cashier.dispose();
    },
  );

  test('QC store switch ignores an older response and late disposal', () async {
    final service = _Qc();
    final notifier = QcTemplateNotifier(service: service);
    final a = notifier.loadTemplates('A');
    final b = notifier.loadTemplates('B');
    service.requests['B']!.complete([
      {'id': 'B'},
    ]);
    await b;
    service.requests['A']!.complete([
      {'id': 'A'},
    ]);
    await a;
    // ignore: invalid_use_of_protected_member
    expect(notifier.state.templates.single['id'], 'B');
    final c = notifier.loadTemplates('C');
    notifier.dispose();
    service.requests['C']!.complete([]);
    await c;
  });

  test(
    'KDS rejects queue overflow without starting extra physical reads',
    () async {
      final coordinator = KdsReadCoordinator(maxPending: 2);
      final gate = Completer<int>();
      var calls = 0;
      Future<int> read() {
        calls++;
        return gate.future;
      }

      final a = coordinator.run(read);
      final b = coordinator.run(read);
      await expectLater(coordinator.run(read), throwsStateError);
      expect(calls, 1);
      gate.complete(1);
      expect(await a, 1);
      expect(await b, 1);
      expect(calls, 2);
    },
  );

  test('runtime features cannot import the application bootstrap', () {
    final violations = Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where(
          (f) => f.path.endsWith('.dart') && !f.path.endsWith('/main.dart'),
        )
        .where(
          (f) => RegExp(
            r'''import\s+['"][^'"]*main\.dart['"]''',
          ).hasMatch(f.readAsStringSync()),
        )
        .map((f) => f.path)
        .toList();
    expect(violations, isEmpty);
  });
}
