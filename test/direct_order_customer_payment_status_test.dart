import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  test('V2 status decodes VAT, proof review, and completion fields', () {
    final status = DirectOrderStatus.fromJson({
      'request_id': 'dd000000-0000-4000-8000-000000000401',
      'store_id': 'dd000000-0000-4000-8000-000000000402',
      'reference_code': 'DSTATUS01',
      'state': 'approved',
      'created_at': '2026-09-10T10:00:00Z',
      'items': <dynamic>[],
      'quote': {
        'id': 'dd000000-0000-4000-8000-000000000403',
        'version': 3,
        'menu_total': 200000,
        'service_charge_total': 10000,
        'delivery_fee_total': 30000,
        'final_total': 240000,
        'status': 'locked',
        'expires_at': '2026-09-10T11:00:00Z',
        'menu_pretax': 181818,
        'menu_vat': 18182,
        'service_charge_pretax': 9091,
        'service_charge_vat': 909,
        'delivery_fee_pretax': 30000,
        'delivery_fee_vat': 0,
        'vat_total': 19091,
        'delivery_payment_mode': 'customer_direct',
      },
      'messages': <dynamic>[],
      'fulfillment': {
        'status': 'completed',
        'pickup_code': '4821',
        'version': 5,
        'updated_at': '2026-09-10T10:45:00Z',
        'completed_at': '2026-09-10T10:45:00Z',
      },
      'dispatch': {
        'grab_tracking_url': 'https://grab.example/order/1',
        'sent_at': '2026-09-10T10:30:00Z',
      },
      'proof_review': {
        'id': 'dd000000-0000-4000-8000-000000000404',
        'reason_code': 'blurry',
        'reason_note': 'Please include the transaction number.',
        'requested_at': '2026-09-10T10:10:00Z',
        'can_resubmit': true,
      },
    });

    expect(status.quote?.vatTotal, 19091);
    expect(status.quote?.deliveryPaymentMode, 'customer_direct');
    expect(status.proofReview?.reasonCode, 'blurry');
    expect(status.fulfillmentStatus, 'completed');
    expect(status.fulfillmentVersion, 5);
    expect(status.completedAt, DateTime.utc(2026, 9, 10, 10, 45));
  });

  test('order history uses the V2 action and preserves each row', () async {
    Map<String, dynamic>? request;
    final service = DirectOrderService(
      invoker: (body) async {
        request = Map<String, dynamic>.from(body);
        return [
          {
            'request_id': 'dd000000-0000-4000-8000-000000000411',
            'reference_code': 'DORDERA1',
            'state': 'quoted',
            'created_at': '2026-09-10T10:00:00Z',
            'item_count': 2,
            'final_total': 240000,
            'fulfillment_status': null,
            'completed_at': null,
            'has_open_proof_review': false,
          },
          {
            'request_id': 'dd000000-0000-4000-8000-000000000412',
            'reference_code': 'DORDERB2',
            'state': 'approved',
            'created_at': '2026-09-10T09:00:00Z',
            'item_count': 1,
            'final_total': 125000,
            'fulfillment_status': 'completed',
            'completed_at': '2026-09-10T09:45:00Z',
            'has_open_proof_review': false,
          },
        ];
      },
    );
    final session = DirectOrderSession(
      id: 'dd000000-0000-4000-8000-000000000413',
      secret: 'fixture-session-secret',
      expiresAt: DateTime.now().add(const Duration(hours: 1)),
    );

    final orders = await service.listOrders(session: session);

    expect(request?['action'], 'orders_v2');
    expect(orders.map((order) => order.referenceCode), [
      'DORDERA1',
      'DORDERB2',
    ]);
    expect(orders.first.isTerminal, isFalse);
    expect(orders.last.isTerminal, isTrue);
  });

  test(
    'payment alert events are emitted once and setting is persisted',
    () async {
      SharedPreferences.setMockInitialValues(const {});
      const service = DirectOrderService();

      expect(await service.loadPaymentAlertEnabled('alert-store'), isTrue);
      await service.setPaymentAlertEnabled('alert-store', false);
      expect(await service.loadPaymentAlertEnabled('alert-store'), isFalse);
      expect(await service.markAlertSeen('alert-store', 'quote:1'), isTrue);
      expect(await service.markAlertSeen('alert-store', 'quote:1'), isFalse);
    },
  );
}
