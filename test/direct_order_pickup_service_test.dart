import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const address = DirectOrderAddress(
    customerName: 'Customer',
    customerPhone: '0901234567',
    formattedAddress: 'Saved delivery address',
    detailAddress: 'Unit 2',
    latitude: 10.8,
    longitude: 106.7,
    addressSource: 'search',
    locationVerified: true,
  );
  final session = DirectOrderSession(
    id: 'session',
    secret: 'secret',
    expiresAt: DateTime.utc(2099),
  );

  test(
    'pickup transmits contact only and preserves a saved delivery address',
    () async {
      SharedPreferences.setMockInitialValues({});
      Map<String, dynamic>? sent;
      final service = DirectOrderService(
        invoker: (body) async {
          sent = body;
          return {
            'request_id': 'pickup',
            'reference_code': 'DPICKUP',
            'state': 'awaiting_quote',
            'idempotent': false,
          };
        },
      );
      await service.saveAddress('store', address);
      await service.submit(
        slug: 'store',
        session: session,
        locale: 'ko',
        cart: {'item': 1},
        itemNotes: {},
        address: address,
        rememberAddress: false,
        fulfillmentType: DirectOrderFulfillmentType.pickup,
      );
      final payload = sent!['payload'] as Map;
      expect(sent!['action'], 'submit_v2');
      expect(payload['fulfillment_type'], 'pickup');
      expect(payload['address'], {
        'customer_name': 'Customer',
        'customer_phone': '0901234567',
        'address_source': 'pickup',
      });
      expect(
        (await service.loadAddress('store'))?.formattedAddress,
        address.formattedAddress,
      );
    },
  );

  test(
    'uncertain submission keeps id and type for retry without a second order',
    () async {
      SharedPreferences.setMockInitialValues({});
      final sentIds = <String>[];
      var fail = true;
      final service = DirectOrderService(
        invoker: (body) async {
          sentIds.add(body['client_request_id'] as String);
          if (fail) {
            fail = false;
            throw const DirectOrderException(
              'DIRECT_ORDER_TEMPORARILY_UNAVAILABLE',
            );
          }
          return {
            'request_id': 'existing',
            'reference_code': 'DEXISTING',
            'state': 'awaiting_quote',
            'idempotent': true,
          };
        },
      );
      Future<DirectOrderSubmission> submit(DirectOrderFulfillmentType type) =>
          service.submit(
            slug: 'store',
            session: session,
            locale: 'ko',
            cart: {'item': 1},
            itemNotes: {},
            address: address,
            rememberAddress: false,
            fulfillmentType: type,
          );
      await expectLater(
        submit(DirectOrderFulfillmentType.delivery),
        throwsA(isA<DirectOrderException>()),
      );
      await expectLater(
        submit(DirectOrderFulfillmentType.pickup),
        throwsA(
          isA<DirectOrderException>().having(
            (e) => e.code,
            'code',
            'DIRECT_ORDER_FULFILLMENT_TYPE_LOCKED',
          ),
        ),
      );
      expect(sentIds.length, 1);
      expect(
        (await submit(DirectOrderFulfillmentType.delivery)).requestId,
        'existing',
      );
      expect(sentIds[0], sentIds[1]);
    },
  );

  test('unknown fulfillment types fail closed', () {
    expect(
      DirectOrderFulfillmentType.fromValue(null),
      DirectOrderFulfillmentType.delivery,
    );
    expect(
      DirectOrderFulfillmentType.fromValue('pickup'),
      DirectOrderFulfillmentType.pickup,
    );
    expect(
      () => DirectOrderFulfillmentType.fromValue('unknown'),
      throwsFormatException,
    );
  });
}
