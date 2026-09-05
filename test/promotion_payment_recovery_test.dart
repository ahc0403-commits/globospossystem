import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/services/payment_service.dart';
import 'package:globos_pos_system/features/payment/payment_provider.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Payments extends PaymentService {
  var calls = 0;
  var boundary = true;
  @override
  Future<Map<String, dynamic>> processPayment({
    required String orderId,
    required String storeId,
    required double amount,
    required String method,
  }) async {
    calls++;
    throw PostgrestException(
      message: 'PAYMENT_AMOUNT_MISMATCH',
      details: boundary ? 'PROMOTION_PRICE_CHANGED' : 'ordinary rejection',
    );
  }
}

class _Cashier extends PaymentNotifier {
  _Cashier(SupabaseClient client, PaymentService payments)
    : super(client: client, payments: payments);
  @override
  Future<void> subscribeRealtime(String storeId) async {}
}

void main() {
  late HttpServer server;
  late SupabaseClient client;
  late _Payments payments;
  late _Cashier cashier;
  final requests = <String>[];
  var failRecovery = false;
  setUp(() async {
    requests.clear();
    failRecovery = false;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((r) async {
      requests.add('${r.method} ${r.uri.path}');
      r.response.headers.contentType = ContentType.json;
      if (r.uri.path.endsWith('/prepare_order_payment_promotions')) {
        final body = jsonDecode(await utf8.decoder.bind(r).join()) as Map;
        expect(body['p_order_ids'], ['order']);
        expect(body['p_store_id'], 'store');
        if (failRecovery) {
          r.response.statusCode = 503;
          r.response.write(jsonEncode({'message': 'fixture failure'}));
        } else {
          r.response.write('null');
        }
      } else if (r.uri.path.endsWith('/restaurants')) {
        r.response.write(
          jsonEncode({'vat_pricing_mode': 'exclusive', 'brands': null}),
        );
      } else {
        r.response.write('[]');
      }
      await r.response.close();
    });
    client = SupabaseClient('http://127.0.0.1:${server.port}', 'fixture');
    payments = _Payments();
    cashier = _Cashier(client, payments);
  });
  tearDown(() async {
    cashier.dispose();
    await client.dispose();
    await server.close(force: true);
  });
  test(
    'opening cashier performs reads without promotion refresh DML',
    () async {
      await cashier.loadOrders('store');
      expect(cashier.state.error, isNull);
      expect(requests, everyElement(startsWith('GET ')));
      expect(requests.where((r) => r.contains('promotion')), isEmpty);
    },
  );
  test(
    'boundary failure prepares once and refreshes without re-submitting payment',
    () async {
      expect(
        await cashier.processPayment('store', 'order', 100, 'CASH'),
        isNull,
      );
      expect(payments.calls, 1);
      expect(
        requests.where((r) => r.contains('prepare_order_payment_promotions')),
        hasLength(1),
      );
      expect(requests.where((r) => r.startsWith('GET ')), isNotEmpty);
      expect(cashier.state.paymentSuccess, isFalse);
      expect(cashier.state.isProcessing, isFalse);
      expect(cashier.state.error, contains('no longer matches'));
    },
  );
  test(
    'failed recovery preserves failed payment and never retries charge',
    () async {
      failRecovery = true;
      expect(
        await cashier.processPayment('store', 'order', 100, 'CASH'),
        isNull,
      );
      expect(payments.calls, 1);
      expect(requests, hasLength(1));
      expect(cashier.state.paymentSuccess, isFalse);
      expect(cashier.state.isProcessing, isFalse);
    },
  );
  test('ordinary payment error never causes promotion mutation', () async {
    payments.boundary = false;
    await cashier.processPayment('store', 'order', 100, 'CASH');
    expect(requests, isEmpty);
    expect(payments.calls, 1);
  });
}
