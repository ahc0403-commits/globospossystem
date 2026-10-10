import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_stage.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_chat_templates.dart';

void main() {
  test('proof submission and handoff never mean fulfillment completed', () {
    expect(
      directOrderStage('awaiting_payment_review', null),
      DirectOrderStage.waiting,
    );
    for (final status in [
      null,
      'pending',
      'preparing',
      'ready',
      'dispatched',
    ]) {
      expect(directOrderStage('approved', status), DirectOrderStage.paid);
    }
    expect(
      directOrderStage('approved', 'completed'),
      DirectOrderStage.completed,
    );
    expect(
      directOrderStage('approved', 'cancelled'),
      DirectOrderStage.exception,
    );
    expect(
      directOrderStage('cancelled', 'completed'),
      DirectOrderStage.exception,
    );
  });
  test('public status retains item and time snapshots', () {
    final status = DirectOrderStatus.fromJson({
      'request_id': 'request',
      'store_id': 'store',
      'reference_code': 'DFIXTURE1',
      'state': 'approved',
      'created_at': '2026-10-06T02:15:00Z',
      'items': [
        {
          'menu_item_id': 'menu',
          'name_ko': '김밥',
          'name_vi': 'Kimbap',
          'name_en': 'Kimbap',
          'unit_price': 100000,
          'quantity': 2,
          'note': '파 제외',
        },
      ],
      'messages': [],
      'quote': null,
      'fulfillment': null,
      'dispatch': null,
      'customer': {
        'customer_name': 'Stored fixture customer',
        'customer_phone': 'Fixture phone',
        'formatted_address': 'Stored fixture address',
        'detail_address': 'Door 7',
        'district': 'Fixture district',
        'ward': 'Fixture ward',
        'customer_note': '수령 전 연락\n문 앞에서 기다려 주세요',
      },
    });
    expect(status.createdAt, DateTime.utc(2026, 10, 6, 2, 15));
    expect(status.items.single.amount, 200000);
    expect(status.items.single.note, '파 제외');
    expect(status.items.single.localizedName('ko'), '김밥');
    expect(status.customer!.customerName, 'Stored fixture customer');
    expect(status.customer!.detailAddress, 'Door 7');
    expect(status.customer!.customerNote, '수령 전 연락\n문 앞에서 기다려 주세요');
  });
  test('customer detail accepts unavailable history and rejects extra PII', () {
    expect(DirectOrderCustomerDetails.fromJson({}).customerName, isNull);
    expect(
      () => DirectOrderCustomerDetails.fromJson({'session_secret': 'fixture'}),
      throwsFormatException,
    );
    expect(
      () => DirectOrderCustomerDetails.fromJson({'customer_phone': 123}),
      throwsFormatException,
    );
  });
  test('status uses v7 in one owning-session request', () async {
    final calls = <Map<String, dynamic>>[];
    final service = DirectOrderService(
      invoker: (body) async {
        calls.add(body);
        return {
          'request_id': 'request',
          'store_id': 'store',
          'reference_code': 'DFIXTURE1',
          'state': 'approved',
          'created_at': '2026-10-06T02:15:00Z',
          'items': [],
          'messages': [],
          'customer': null,
        };
      },
    );
    final status = await service.fetchStatus(
      session: DirectOrderSession(
        id: 'session',
        secret: 'fixture-secret',
        expiresAt: DateTime.utc(2099),
      ),
      requestId: 'request',
    );
    expect(calls.single['action'], 'status_v7');
    expect(calls.single['request_id'], 'request');
    expect(status.customer, isNull);
  });
  test(
    'push subscription is one session-bound request, unsubscribe excludes the token',
    () async {
      final calls = <Map<String, dynamic>>[];
      final service = DirectOrderService(
        invoker: (body) async {
          calls.add(body);
          return {'enabled': body['enabled']};
        },
      );
      final session = DirectOrderSession(
        id: 'session',
        secret: 'fixture-secret',
        expiresAt: DateTime.utc(2099),
      );
      await service.setPushSubscription(
        session: session,
        deviceId: 'device',
        locale: 'ko',
        enabled: true,
        token: 'fixture-token',
      );
      await service.setPushSubscription(
        session: session,
        deviceId: 'device',
        locale: 'ko',
        enabled: false,
      );
      expect(calls.length, 2);
      expect(calls.first['session_id'], 'session');
      expect(calls.first['action'], 'push_subscription');
      expect(calls.last.containsKey('token'), false);
    },
  );
  test(
    'quote templates distinguish included, separate and pickup delivery fees',
    () {
      String draft(
        bool pickup,
        bool separate, {
        DirectOrderChatTemplate template = DirectOrderChatTemplate.quote,
        int? fee,
      }) => directOrderChatDraft(
        template: template,
        locale: 'ko',
        storeName: 'Fixture',
        referenceCode: 'DFIXTURE1',
        customerName: 'Fixture',
        phone: 'Fixture phone',
        address: 'Fixture address',
        pickup: pickup,
        customerPaysDriver: separate,
        deliveryFee: fee,
      );
      expect(draft(false, true), contains('기사에게 별도로 지급'));
      expect(draft(false, false), contains('견적에 포함'));
      expect(draft(true, true), contains('배송비는 없습니다'));
      expect(
        () => draft(false, true, template: DirectOrderChatTemplate.deliveryFee),
        throwsArgumentError,
      );
      expect(
        draft(
          false,
          true,
          template: DirectOrderChatTemplate.deliveryFee,
          fee: 25000,
        ),
        contains('25.000 VND'),
      );
    },
  );
}
