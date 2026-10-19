import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';

void main() {
  const request = '90000000-0000-4000-8000-000000000001';
  const key = 'fixture-order-access-key';
  setUp(() => SharedPreferences.setMockInitialValues({}));
  test(
    'a fresh browser restores a single order directly from link credentials',
    () async {
      final calls = <Map<String, dynamic>>[];
      final service = DirectOrderService(
        invoker: (body) async {
          calls.add(body);
          if (body['action'] == 'resume_order') {
            return {
              'session_id': request,
              'secret': key,
              'expires_at': '2099-01-01T00:00:00Z',
              'order_scoped': true,
            };
          }
          return {
            'message_id': 'message',
            'created_at': '2026-10-09T01:00:00Z',
          };
        },
      );
      final session = await service.resumeOrder(
        slug: 'fixture',
        requestId: request,
        accessKey: key,
      );
      expect(session.orderScoped, isTrue);
      expect(session.credentials, {
        'session_id': request,
        'secret': key,
        'order_scoped': true,
      });
      await service.sendMessage(
        session: session,
        requestId: request,
        message: 'Please confirm my order',
      );
      expect(calls.last['order_scoped'], isTrue);
      expect(await service.loadActiveRequestId('fixture'), request);
      expect(await service.loadCachedSession('fixture'), isNull);
      final restored = await service.loadRestorableSession('fixture');
      expect(restored!.credentials, session.credentials);
    },
  );
  test(
    'closing one order clears its access while retaining the saved address and another order key',
    () async {
      final service = DirectOrderService(invoker: (_) async => {});
      const address = DirectOrderAddress(
        customerName: 'Fixture',
        customerPhone: '+84901234567',
        formattedAddress: 'Fixture address',
        detailAddress: '',
        latitude: 10,
        longitude: 106,
        addressSource: 'search',
        locationVerified: true,
      );
      await service.saveAddress('fixture', address);
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        'direct_order_access_v1_fixture_$request',
        key,
      );
      await preferences.setString(
        'direct_order_access_v1_fixture_other',
        'other-key',
      );
      await service.saveSelectedRequest('fixture', request);
      await preferences.setStringList('direct_order_seen_alerts_v1_fixture', [
        '$request:quote',
        'other:quote',
      ]);
      await preferences.setString(
        'direct_order_push_device_fixture:$request',
        'device',
      );
      await service.clearOrderAccess('fixture', request);
      expect(
        preferences.getString('direct_order_access_v1_fixture_$request'),
        isNull,
      );
      expect(
        preferences.getString('direct_order_access_v1_fixture_other'),
        'other-key',
      );
      expect(
        (await service.loadAddress('fixture'))!.formattedAddress,
        address.formattedAddress,
      );
      expect(await service.loadActiveRequestId('fixture'), isNull);
      expect(preferences.getStringList('direct_order_seen_alerts_v1_fixture'), [
        'other:quote',
      ]);
      expect(
        preferences.getString('direct_order_push_device_fixture:$request'),
        isNull,
      );
    },
  );
  test(
    'an ended cached link returns to the menu without recreating the ended order',
    () async {
      final service = DirectOrderService(
        invoker: (body) async {
          throw const DirectOrderException('DIRECT_ORDER_ORDER_CLOSED');
        },
      );
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString(
        'direct_order_access_v1_fixture_$request',
        key,
      );
      await service.saveSelectedRequest('fixture', request);
      expect(await service.loadRestorableSession('fixture'), isNull);
      expect(await service.loadActiveRequestId('fixture'), isNull);
      expect(
        preferences.getString('direct_order_access_v1_fixture_$request'),
        isNull,
      );
    },
  );
}
