import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('lost submit response reuses the same idempotency key', () async {
    SharedPreferences.setMockInitialValues(const {});
    final clientRequestIds = <String>[];
    var attempt = 0;
    final service = DirectOrderService(
      invoker: (body) async {
        clientRequestIds.add(body['client_request_id'] as String);
        attempt += 1;
        if (attempt == 1) {
          throw const DirectOrderException(
            'DIRECT_ORDER_TEMPORARILY_UNAVAILABLE',
          );
        }
        return {
          'request_id': 'dd000000-0000-4000-8000-000000000101',
          'reference_code': 'D1234ABCD',
          'state': 'awaiting_quote',
          'idempotent': true,
        };
      },
    );
    final session = DirectOrderSession(
      id: 'dd000000-0000-4000-8000-000000000102',
      secret: 'fixture-session-secret',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );
    const address = DirectOrderAddress(
      customerName: 'Nguyen Van A',
      customerPhone: '+84901234567',
      formattedAddress: '123 Nguyen Hue, District 1, HCMC',
      detailAddress: 'Floor 4, room 401',
      latitude: 10.775,
      longitude: 106.704,
      addressSource: 'search',
      locationVerified: true,
    );

    Future<DirectOrderSubmission> submit() => service.submit(
      slug: 'retry-store',
      session: session,
      locale: 'en',
      cart: const {'dd000000-0000-4000-8000-000000000103': 1},
      itemNotes: const {},
      address: address,
      rememberAddress: false,
    );

    await expectLater(
      submit(),
      throwsA(
        isA<DirectOrderException>().having(
          (error) => error.code,
          'code',
          'DIRECT_ORDER_TEMPORARILY_UNAVAILABLE',
        ),
      ),
    );
    final result = await submit();

    expect(result.requestId, 'dd000000-0000-4000-8000-000000000101');
    expect(clientRequestIds, hasLength(2));
    expect(clientRequestIds[1], clientRequestIds[0]);

    final preferences = await SharedPreferences.getInstance();
    expect(
      preferences.getString('direct_order_pending_submit_v1_retry-store'),
      isNull,
    );
    final active =
        jsonDecode(
              preferences.getString('direct_order_request_v1_retry-store')!,
            )
            as Map<String, dynamic>;
    expect(active['request_id'], result.requestId);
  });

  test('message submission sends only the author original', () async {
    Map<String, dynamic>? sent;
    final service = DirectOrderService(
      invoker: (body) async {
        sent = Map<String, dynamic>.from(body);
        return {
          'message_id': 'dd000000-0000-4000-8000-000000000205',
          'created_at': '2026-08-22T10:02:00Z',
        };
      },
    );
    final session = DirectOrderSession(
      id: 'dd000000-0000-4000-8000-000000000206',
      secret: 'fixture-session-secret',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );

    final message = await service.sendMessage(
      session: session,
      requestId: 'dd000000-0000-4000-8000-000000000207',
      message: 'Please call when you arrive.',
    );

    expect(sent?['action'], 'message');
    expect(sent?['message'], 'Please call when you arrive.');
    expect(sent?.containsKey('locale'), isFalse);
    expect(message.senderType, 'customer');
    expect(message.body, 'Please call when you arrive.');
    expect(message.createdAt, DateTime.utc(2026, 8, 22, 10, 2));
  });
}
