import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_stage.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_chat_templates.dart';

void main() {
  test(
    'customer fulfillment follows verified cooking, packing, handoff and pickup',
    () {
      expect(
        directOrderCustomerProgress('awaiting_payment_review', null),
        'awaiting_payment_review',
      );
      expect(
        directOrderCustomerProgress('approved', 'preparing'),
        'customer_preparing',
      );
      expect(
        directOrderCustomerProgress(
          'approved',
          'preparing',
          cookingComplete: true,
        ),
        'customer_cooked',
      );
      expect(
        directOrderCustomerProgress('approved', 'ready', cookingComplete: true),
        'customer_packed',
      );
      expect(
        directOrderCustomerProgress(
          'approved',
          'dispatched',
          handoffConfirmed: true,
        ),
        'customer_shipping',
      );
      expect(
        directOrderCustomerProgress('approved', 'completed'),
        'customer_delivered',
      );
      expect(
        directOrderCustomerProgress('approved', 'ready', isPickup: true),
        'customer_pickup_ready',
      );
      expect(
        directOrderCustomerProgress('approved', 'completed', isPickup: true),
        'customer_collected',
      );
      expect(
        directOrderCustomerProgress(
          'cancelled',
          'completed',
          cookingComplete: true,
        ),
        'cancelled',
      );
    },
  );

  test('legacy KDS dispatch alone does not claim driver handoff', () {
    expect(
      directOrderCustomerProgress(
        'approved',
        'dispatched',
        handoffConfirmed: false,
      ),
      'customer_packed',
    );
  });
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
    });
    expect(status.createdAt, DateTime.utc(2026, 10, 6, 2, 15));
    expect(status.items.single.amount, 200000);
    expect(status.items.single.note, '파 제외');
    expect(status.items.single.localizedName('ko'), '김밥');
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
