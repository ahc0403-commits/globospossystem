import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/core/hardware/receipt_builder.dart';
import 'package:globos_pos_system/core/hardware/receipt_delivery_policy.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_service.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_models.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_stage.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_details_sheet.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_copy.dart';
import 'package:globos_pos_system/features/direct_order/direct_order_chat_templates.dart';
import 'package:globos_pos_system/features/digital_receipt/digital_receipt_model.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test('recipient chat advice needs no fare or customer booking approval', () {
    for (final locale in ['ko', 'vi', 'en']) {
      final copy = DirectOrderCopy(locale);
      for (final fee in <int?>[null, 30000, 40000]) {
        final draft = directOrderChatDraft(
          template: DirectOrderChatTemplate.deliveryFee,
          locale: locale,
          storeName: 'Store',
          referenceCode: 'ORDER',
          customerName: 'Customer',
          phone: 'Phone',
          address: 'Address',
          pickup: false,
          customerPaysDriver: true,
          recipientDeliveryPolicy: true,
          deliveryFee: fee,
        );
        expect(draft, contains(copy.customerPaysDriverHelp));
        expect(draft.contains(copy.recipientFeeReference), fee != null);
        expect(draft, isNot(contains('확인해 주시면')));
        expect(draft, isNot(contains('Sau khi quý khách xác nhận')));
        expect(draft, isNot(contains('Once you confirm')));
      }
    }
  });
  testWidgets('unquoted recipient order has no pending delivery price', (
    tester,
  ) async {
    final copy = DirectOrderCopy('en');
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DirectOrderDetailsSheet(
            languageCode: 'en',
            status: const DirectOrderStatus(
              requestId: 'request',
              referenceCode: 'ORDER',
              state: 'awaiting_quote',
              messages: [],
              delivery: DirectOrderDelivery(),
              support: {'delivery_policy_version': 2},
            ),
          ),
        ),
      ),
    );
    expect(find.text(copy.customerPaysDriverHelp), findsOneWidget);
    expect(find.text(copy.deliveryFeePending), findsNothing);
    expect(find.text(copy.amountPending), findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
  test('booked driver remains packing until physical handoff', () {
    expect(
      directOrderCustomerProgress(
        'approved',
        'preparing',
        cookingComplete: true,
        driverBooked: true,
      ),
      'customer_driver_booked',
    );
    expect(
      directOrderCustomerProgress('approved', 'ready', driverBooked: true),
      'customer_packed',
    );
    expect(
      directOrderCustomerProgress('approved', 'dispatched', driverBooked: true),
      'customer_packed',
    );
    expect(
      directOrderCustomerProgress(
        'approved',
        'dispatched',
        driverBooked: true,
        handoffConfirmed: true,
      ),
      'customer_shipping',
    );
    expect(
      directOrderCustomerProgress(
        'approved',
        'preparing',
        cookingComplete: true,
        driverBooked: true,
        isPickup: true,
      ),
      'customer_cooked',
    );
  });
  test(
    'driver slip distinguishes food payment and separate courier collection',
    () async {
      for (final method in ['delivery', 'pickup']) {
        final ticket = PrintTicket.fromPayload({
          'ticket': 'delivery_driver_receipt',
          'fulfillment_method': method,
          'delivery_payment_mode': 'customer_direct',
          'menu_total': 108000,
          'final_total': 108000,
          'delivery_fee_total': 0,
          'items': <dynamic>[],
        });
        final text = String.fromCharCodes(
          await ReceiptBuilder.buildKitchenTicket(ticket),
        );
        if (method == 'delivery') {
          expect(text, contains(driverFoodPaidVi));
          expect(text, contains(driverDoNotCollectFoodVi));
          expect(text, contains(driverCollectDeliveryVi));
          expect(text, isNot(contains('Khach can tra: 0 VND')));
          expect(text, isNot(contains('KHONG THU THEM TIEN CUA KHACH')));
          expect(text, isNot(contains('Phi giao hang Grab')));
        } else {
          expect(text, isNot(contains(driverCollectDeliveryVi)));
        }
        expect(text, contains('108,000 VND'));
      }
    },
  );
  test(
    'customer receipt uses saved payer without changing store total',
    () async {
      for (final mode in ['customer_direct', 'store_prepaid']) {
        final queued = QueuedPaymentReceipt.fromPayload({
          'delivery_payment_mode': mode,
          'total_amount': 108000,
          'fulfillment_method': 'delivery',
          'items': <dynamic>[],
        });
        final text = String.fromCharCodes(
          await ReceiptBuilder.buildPaymentReceipt(
            restaurantName: 'GLOBOS',
            tableNumber: '-',
            items: queued.items,
            totalAmount: queued.totalAmount,
            paymentMethod: 'BANKTRANSFER',
            paidAt: DateTime.utc(2026),
            directOrderReference: 'DTEST',
            fulfillmentMethod: 'delivery',
            deliveryPaymentMode: queued.deliveryPaymentMode,
          ),
        );
        expect(text, contains('108,000'));
        expect(text.contains('Tra truc tiep'), mode == 'customer_direct');
      }
      expect(
        DigitalReceipt.fromJson({
          'delivery_payment_mode': 'customer_direct',
          'total_amount': 108000,
        }).deliveryPaymentMode,
        'customer_direct',
      );
    },
  );
  test(
    'customer general attachment retries same path without a charge or proof action',
    () async {
      final calls = <Map<String, dynamic>>[];
      var stored = false, uploaded = 0;
      final service = DirectOrderService(
        invoker: (body) async {
          calls.add(body);
          if (body['action'] == 'customer_chat_attachment_commit') {
            if (!stored) {
              throw const DirectOrderException('PROOF_UPLOAD_INCOMPLETE');
            }
            return {'message_id': 'general'};
          }
          return {'token': 'upload'};
        },
        proofUploader: (path, token, bytes, mime) async {
          uploaded++;
          stored = true;
        },
      );
      final session = DirectOrderSession(
        id: 'session',
        secret: 'secret',
        expiresAt: DateTime.utc(2030),
      );
      await service.uploadSupportAttachment(
        session: session,
        requestId: 'order',
        path: 'store/order/file.pdf',
        filename: 'address.pdf',
        mimeType: 'application/pdf',
        bytes: Uint8List.fromList([37, 80, 68, 70]),
      );
      await service.uploadSupportAttachment(
        session: session,
        requestId: 'order',
        path: 'store/order/file.pdf',
        filename: 'address.pdf',
        mimeType: 'application/pdf',
        bytes: Uint8List.fromList([37, 80, 68, 70]),
      );
      expect(uploaded, 1);
      expect(calls.any((b) => b.containsKey('charge_id')), false);
      expect(calls.map((b) => b['action']).toSet(), {
        'customer_chat_attachment_upload',
        'customer_chat_attachment_commit',
      });
    },
  );
}
