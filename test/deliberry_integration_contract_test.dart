import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:globos_pos_system/features/delivery/delivery_models.dart';

String readRepoFile(String path) => File(path).readAsStringSync();

void main() {
  group('Deliberry integration contract', () {
    test('hardens Deliberry read views with invoker security', () {
      final migration = File(
        'supabase/migrations/299_deliberry_integration_security_closure.sql',
      );
      final closureMigration = File(
        'supabase/migrations/20260707011000_external_store_view_security_schema_closure.sql',
      );
      final schema = File('supabase/schema.sql');

      expect(migration.existsSync(), isTrue);
      expect(closureMigration.existsSync(), isTrue);
      expect(schema.existsSync(), isTrue);

      final sql = migration.readAsStringSync();
      final closureSql = closureMigration.readAsStringSync();
      final schemaSql = schema.readAsStringSync();
      for (final viewName in [
        'v_external_store_sales',
        'v_external_store_overview',
        'v_daily_revenue_by_channel',
        'v_settlement_summary',
      ]) {
        expect(
          sql,
          contains(
            'ALTER VIEW public.$viewName SET (security_invoker = true);',
          ),
          reason: '$viewName must not bypass table RLS through view ownership.',
        );
      }

      for (final viewName in [
        'v_external_store_sales',
        'v_external_store_overview',
      ]) {
        expect(closureSql, contains('CREATE OR REPLACE VIEW public.$viewName'));
        expect(closureSql, contains('WITH (security_invoker = true) AS'));
        expect(closureSql, contains('AND public.is_super_admin()'));
        expect(
          closureSql,
          contains(
            'REVOKE ALL ON public.$viewName FROM PUBLIC, anon, authenticated',
          ),
        );
        expect(
          closureSql,
          contains(
            'GRANT SELECT ON public.$viewName TO authenticated, service_role',
          ),
        );
        expect(
          schemaSql,
          contains(
            'CREATE OR REPLACE VIEW "public"."$viewName" WITH ("security_invoker"=',
          ),
        );
      }

      expect(schemaSql, contains('"public"."is_super_admin"()'));
      expect(
        schemaSql,
        isNot(
          contains(
            'GRANT ALL ON TABLE "public"."v_external_store_sales" TO "anon"',
          ),
        ),
      );
      expect(
        schemaSql,
        isNot(
          contains(
            'GRANT ALL ON TABLE "public"."v_external_store_overview" TO "anon"',
          ),
        ),
      );
    });

    test('settlement summary exposes the active store_id contract', () {
      final sql = readRepoFile(
        'supabase/migrations/299_deliberry_integration_security_closure.sql',
      );
      final provider = readRepoFile(
        'lib/features/delivery/delivery_settlement_provider.dart',
      );
      final model = readRepoFile('lib/features/delivery/delivery_models.dart');

      expect(sql, contains('ds.restaurant_id AS store_id'));
      expect(provider, contains(".from('v_settlement_summary')"));
      expect(provider, contains(".eq('store_id', storeId)"));
      expect(provider, contains(".select('gross_amount, payload')"));
      expect(provider, contains('_isMerchantCollectedOffline'));
      expect(model, contains("json['store_id'] ?? json['restaurant_id']"));
    });

    test(
      'order feed reads offline acknowledgment and explicit next cursor',
      () {
        final request = DeliberryPosOrderFeedRequest(
          cursor: const DeliberryOrderFeedCursor(
            updatedAt: '2026-06-12T00:00:00Z',
            id: 'DLB-CURSOR-1000',
          ),
        );
        final uri = request.toUri(
          Uri.parse('https://example.supabase.co/functions/v1'),
        );

        expect(uri.path, '/functions/v1/pos-integration/orders');
        expect(uri.queryParameters['limit'], '100');
        expect(
          uri.queryParameters['cursor_updated_at'],
          '2026-06-12T00:00:00Z',
        );
        expect(uri.queryParameters['cursor_id'], 'DLB-CURSOR-1000');
        expect(request.authorizationHeaders('pos-token'), {
          'Authorization': 'Bearer pos-token',
        });

        final page = DeliberryPosOrderFeedPage.fromJson({
          'items': [
            {
              'order_id': 'DLB-1001',
              'updated_at': '2026-06-12T03:00:00Z',
              'payment_status': 'pending',
              'offline_collection_acknowledgment': {
                'acknowledged': true,
                'payment_method': 'cash',
                'acknowledged_at': '2026-06-12T10:05:00+07:00',
                'acknowledged_by': 'merchant-staff-7',
              },
            },
          ],
          'next_cursor': {
            'updated_at': '2026-06-13T00:00:00Z',
            'id': 'DLB-CURSOR-2000',
          },
        });

        expect(page.items, hasLength(1));
        expect(
          page.items.single.offlineCollectionAcknowledgment?.method,
          'cash',
        );
        expect(page.nextCursor?.updatedAt, '2026-06-13T00:00:00Z');
        expect(page.nextCursor?.id, 'DLB-CURSOR-2000');
        expect(
          page.nextCursor?.updatedAt,
          isNot(page.items.single.updatedAt),
          reason:
              'The next cursor must come from response.next_cursor, not the '
              'last order updated_at.',
        );

        final localFields = page.items.single.toOfflineCollectionOrderFields();
        expect(localFields, {
          'offline_collection_acknowledged': true,
          'offline_collection_method': 'cash',
          'offline_collection_acknowledged_at': '2026-06-12T10:05:00+07:00',
          'offline_collection_acknowledged_by': 'merchant-staff-7',
        });
        expect(localFields.keys, isNot(contains('payment_status')));
        expect(localFields.keys, isNot(contains('payment_method')));
        expect(localFields.keys, isNot(contains('card_status')));
        expect(localFields.keys, isNot(contains('pg_transaction_id')));
      },
    );

    test('missing order feed cursor is not inferred from order timestamps', () {
      final page = DeliberryPosOrderFeedPage.fromJson({
        'items': [
          {'id': 'DLB-1002', 'updated_at': '2026-06-12T04:00:00Z'},
        ],
      });

      expect(page.nextCursor, isNull);
      expect(page.items.single.toOfflineCollectionOrderFields(), isEmpty);
    });

    test('operational order inbox is active-store scoped and non-financial', () {
      final detail = DeliberryOperationalOrder.fromJson({
        'store_id': 'store-a',
        'external_order_id': 'DLB-D1-DETAIL',
        'status': 'customer_cancelled',
        'trace_id': 'trace-d1-detail',
        'payload_version': 'deliberry.operational_order.v1',
        'channel_id': 'DELIBERRY',
        'customer_note': 'No onion',
        'gross_amount': 70000,
        'payment_method': 'cash',
        'payment_status': 'pending',
        'collection_mode': 'merchant_collected_offline',
        'items': [
          {
            'name': 'Pho',
            'quantity': 1,
            'unit_price': 70000,
            'options': ['extra herbs'],
          },
        ],
      });

      expect(detail.status, DeliberryOperationalOrderStatus.customerCancelled);
      expect(detail.traceId, 'trace-d1-detail');
      expect(detail.payloadVersion, deliberryOperationalPayloadVersion);
      expect(detail.channelId, deliberryOperationalChannelId);
      expect(detail.customerNote, 'No onion');
      expect(detail.grossAmount, 70000);
      expect(detail.paymentMethod, 'cash');
      expect(detail.paymentStatus, 'pending');
      expect(detail.collectionMode, 'merchant_collected_offline');
      expect(detail.items.single.name, 'Pho');
      expect(detail.items.single.options, ['extra herbs']);
      expect(
        deliberryOperationalOrderStatusFromWire('delivered'),
        DeliberryOperationalOrderStatus.delivered,
      );

      var inbox = const DeliberryOperationalOrderInbox();

      final firstReceive = DeliberryOperationalOrderEvent(
        eventId: 'evt-received-1',
        traceId: 'trace-d1-001',
        eventType: deliberryOrderReceivedEvent,
        storeId: 'store-a',
        externalOrderId: 'DLB-D1-001',
        payload: const {
          'external_order_id': 'DLB-D1-001',
          'customer_note': 'No onion',
          'items': [
            {
              'name': 'Pho',
              'quantity': 1,
              'unit_price': 70000,
              'options': ['extra herbs'],
            },
          ],
        },
      );

      inbox = inbox.applyEvent(firstReceive);
      inbox = inbox.applyEvent(firstReceive);
      inbox = inbox.applyEvent(
        const DeliberryOperationalOrderEvent(
          eventId: 'evt-received-retry-2',
          eventType: deliberryOrderReceivedEvent,
          storeId: 'store-a',
          externalOrderId: 'DLB-D1-001',
        ),
      );
      inbox = inbox.applyEvent(
        const DeliberryOperationalOrderEvent(
          eventId: 'evt-received-other-store',
          eventType: deliberryOrderReceivedEvent,
          storeId: 'store-b',
          externalOrderId: 'DLB-D1-002',
        ),
      );

      expect(inbox.ordersForActiveStore('store-a'), hasLength(1));
      expect(inbox.ordersForActiveStore('store-b'), hasLength(1));
      expect(
        inbox.ordersForActiveStore('store-a').single.externalOrderId,
        'DLB-D1-001',
      );
      expect(inbox.processedEventIds, hasLength(3));
      expect(inbox.posRevenueRowsCreated, 0);

      final storeOrder = inbox.ordersForActiveStore('store-a').single;
      expect(storeOrder.createsPosRevenue, isFalse);
      expect(storeOrder.status, DeliberryOperationalOrderStatus.newOrder);

      final accepted = storeOrder.actionEvent(
        action: DeliberryOperationalOrderAction.accept,
        eventId: 'evt-accepted-1',
        actorId: 'manager-1',
        role: 'store_admin',
        activeStoreId: 'store-a',
        accessibleStoreIds: const ['store-a'],
      );
      expect(accepted.eventType, deliberryOrderAcceptedEvent);
      expect(accepted.traceId, 'trace-d1-001');
      expect(accepted.payloadVersion, deliberryOperationalPayloadVersion);
      expect(accepted.channelId, deliberryOperationalChannelId);
      expect(accepted.createsPosRevenue, isFalse);

      inbox = inbox.applyEvent(accepted);
      expect(
        inbox.ordersForActiveStore('store-a').single.status,
        DeliberryOperationalOrderStatus.accepted,
      );
      inbox = inbox.applyEvent(
        const DeliberryOperationalOrderEvent(
          eventId: 'evt-received-after-accept',
          eventType: deliberryOrderReceivedEvent,
          storeId: 'store-a',
          externalOrderId: 'DLB-D1-001',
        ),
      );
      expect(
        inbox.ordersForActiveStore('store-a').single.status,
        DeliberryOperationalOrderStatus.accepted,
        reason: 'A delayed receive retry must not downgrade an actioned order.',
      );

      inbox = inbox.applyEvent(
        const DeliberryOperationalOrderEvent(
          eventId: 'evt-received-terminal-reject-order',
          eventType: deliberryOrderReceivedEvent,
          storeId: 'store-a',
          externalOrderId: 'DLB-D1-REJECT',
        ),
      );
      inbox = inbox.applyEvent(
        const DeliberryOperationalOrderEvent(
          eventId: 'evt-rejected-terminal',
          eventType: deliberryOrderRejectedEvent,
          storeId: 'store-a',
          externalOrderId: 'DLB-D1-REJECT',
          reason: 'Sold out',
        ),
      );
      inbox = inbox.applyEvent(
        const DeliberryOperationalOrderEvent(
          eventId: 'evt-ready-after-reject',
          eventType: deliberryOrderReadyEvent,
          storeId: 'store-a',
          externalOrderId: 'DLB-D1-REJECT',
        ),
      );
      expect(
        inbox
            .ordersForActiveStore('store-a')
            .singleWhere((order) => order.externalOrderId == 'DLB-D1-REJECT')
            .status,
        DeliberryOperationalOrderStatus.rejected,
        reason:
            'Terminal local states must match the DB action projection guard.',
      );
      inbox = inbox.applyEvent(
        const DeliberryOperationalOrderEvent(
          eventId: 'evt-ready-before-receive',
          eventType: deliberryOrderReadyEvent,
          storeId: 'store-a',
          externalOrderId: 'DLB-D1-OUT-OF-ORDER',
          eventSequence: 2,
        ),
      );
      expect(
        inbox
            .ordersForActiveStore('store-a')
            .singleWhere(
              (order) => order.externalOrderId == 'DLB-D1-OUT-OF-ORDER',
            )
            .status,
        DeliberryOperationalOrderStatus.newOrder,
        reason: 'READY before RECEIVED must not create a ready order.',
      );
      expect(
        inbox.transitionAnomalies
            .where(
              (anomaly) =>
                  anomaly.externalOrderId == 'DLB-D1-OUT-OF-ORDER' &&
                  anomaly.issue ==
                      DeliberryOperationalOrderTransitionIssue
                          .illegalTransition,
            )
            .length,
        1,
      );

      expect(
        canPerformDeliberryOperationalOrderAction(
          action: DeliberryOperationalOrderAction.accept,
          role: 'cashier',
          activeStoreId: 'store-a',
          orderStoreId: 'store-a',
        ),
        isFalse,
      );
      expect(
        canPerformDeliberryOperationalOrderAction(
          action: DeliberryOperationalOrderAction.reject,
          role: 'brand_admin',
          activeStoreId: 'store-b',
          orderStoreId: 'store-a',
          accessibleStoreIds: const ['store-a', 'store-b'],
        ),
        isFalse,
      );
      expect(
        canPerformDeliberryOperationalOrderAction(
          action: DeliberryOperationalOrderAction.ready,
          role: 'kitchen',
          activeStoreId: 'store-a',
          orderStoreId: 'store-a',
          accessibleStoreIds: const ['store-a'],
        ),
        isTrue,
      );
      expect(
        () => storeOrder.actionEvent(
          action: DeliberryOperationalOrderAction.reject,
          eventId: 'evt-rejected-1',
          actorId: 'manager-1',
          role: 'store_admin',
          activeStoreId: 'store-a',
        ),
        throwsStateError,
      );
    });

    test(
      'operational state machine survives 1000+ duplicate and out-of-order events',
      () {
        var inbox = const DeliberryOperationalOrderInbox();
        const orderCount = 1001;

        for (var index = 0; index < orderCount; index += 1) {
          final externalOrderId =
              'DLB-STORM-${index.toString().padLeft(4, '0')}';
          final received = DeliberryOperationalOrderEvent(
            eventId: 'evt-$externalOrderId-received',
            eventType: deliberryOrderReceivedEvent,
            storeId: 'store-a',
            externalOrderId: externalOrderId,
            eventSequence: 1,
          );
          final accepted = DeliberryOperationalOrderEvent(
            eventId: 'evt-$externalOrderId-accepted',
            eventType: deliberryOrderAcceptedEvent,
            storeId: 'store-a',
            externalOrderId: externalOrderId,
            eventSequence: 2,
          );
          final ready = DeliberryOperationalOrderEvent(
            eventId: 'evt-$externalOrderId-ready',
            eventType: deliberryOrderReadyEvent,
            storeId: 'store-a',
            externalOrderId: externalOrderId,
            eventSequence: 3,
          );
          final delivered = DeliberryOperationalOrderEvent(
            eventId: 'evt-$externalOrderId-delivered',
            eventType: deliberryOrderDeliveredEvent,
            storeId: 'store-a',
            externalOrderId: externalOrderId,
            eventSequence: 4,
          );

          inbox = inbox.applyEvent(received);
          inbox = inbox.applyEvent(received);
          inbox = inbox.applyEvent(accepted);
          inbox = inbox.applyEvent(ready);
          inbox = inbox.applyEvent(delivered);
          inbox = inbox.applyEvent(delivered);
          inbox = inbox.applyEvent(
            DeliberryOperationalOrderEvent(
              eventId: 'evt-$externalOrderId-stale-received',
              eventType: deliberryOrderReceivedEvent,
              storeId: 'store-a',
              externalOrderId: externalOrderId,
              eventSequence: 1,
            ),
          );
          inbox = inbox.applyEvent(
            DeliberryOperationalOrderEvent(
              eventId: 'evt-$externalOrderId-illegal-accepted',
              eventType: deliberryOrderAcceptedEvent,
              storeId: 'store-a',
              externalOrderId: externalOrderId,
              eventSequence: 5,
            ),
          );
        }

        final summary = inbox.reconcileActiveStore(
          'store-a',
          expectedExternalOrderIds: [
            for (var index = 0; index < orderCount; index += 1)
              'DLB-STORM-${index.toString().padLeft(4, '0')}',
            'DLB-STORM-MISSING',
          ],
        );

        expect(inbox.ordersForActiveStore('store-a'), hasLength(orderCount));
        expect(
          inbox
              .ordersForActiveStore('store-a')
              .every(
                (order) =>
                    order.status == DeliberryOperationalOrderStatus.delivered &&
                    order.lastEventSequence == 4,
              ),
          isTrue,
        );
        expect(summary.orderCount, orderCount);
        expect(
          summary.statusCounts[DeliberryOperationalOrderStatus.delivered],
          orderCount,
        );
        expect(summary.processedEventCount, orderCount * 6);
        expect(summary.staleEventCount, orderCount);
        expect(summary.illegalTransitionCount, orderCount);
        expect(summary.hasStateMachineAnomalies, isTrue);
        expect(summary.isFinanciallyBalanced, isTrue);
        expect(summary.revenueRowCount, 0);
        expect(summary.missingExternalOrderIds, ['DLB-STORM-MISSING']);
      },
    );

    test('operational order migration is scoped and settlement-safe', () {
      final sql = readRepoFile(
        'supabase/migrations/20260614000000_deliberry_operational_order_d1.sql',
      );

      expect(
        sql,
        contains(
          'CREATE TABLE IF NOT EXISTS public.deliberry_operational_orders',
        ),
      );
      expect(
        sql,
        contains(
          'restaurant_id UUID NOT NULL REFERENCES public.restaurants(id)',
        ),
      );
      for (final field in [
        'trace_id TEXT NOT NULL',
        "payload_version TEXT NOT NULL DEFAULT 'deliberry.operational_order.v1'",
        "channel_id TEXT NOT NULL DEFAULT 'DELIBERRY'",
        'state_version INTEGER NOT NULL DEFAULT 0',
        'attempt_count INTEGER NOT NULL DEFAULT 0',
        'last_event_sequence BIGINT NOT NULL DEFAULT 0',
        'event_sequence BIGINT NOT NULL DEFAULT 0',
        'state_applied BOOLEAN NOT NULL DEFAULT false',
        'state_error TEXT NULL',
        'last_error TEXT NULL',
        'processed_at TIMESTAMPTZ NULL',
        'dead_letter_at TIMESTAMPTZ NULL',
      ]) {
        expect(sql, contains(field));
      }
      expect(
        sql,
        contains('UNIQUE (restaurant_id, source_system, external_order_id)'),
      );
      expect(sql, contains('UNIQUE (restaurant_id, source_system, event_id)'));
      expect(sql, contains('pg_advisory_xact_lock'));
      expect(sql, contains('DELIBERRY_ORDER_INVALID_STATE_TRANSITION'));
      expect(sql, contains('DELIBERRY_ORDER_STALE_EVENT_SEQUENCE'));
      expect(
        sql,
        contains("IF p_event_status = 'new' THEN\n      RETURN 'new';"),
        reason:
            'A missing order may only be created from RECEIVED/new; READY '
            'before RECEIVED must be logged as an invalid transition.',
      );
      for (final status in [
        "'new'",
        "'accepted'",
        "'rejected'",
        "'ready'",
        "'delivered'",
        "'customer_cancelled'",
      ]) {
        expect(sql, contains(status));
      }
      for (final eventType in [
        'DELIBERRY_ORDER_RECEIVED',
        'DELIBERRY_ORDER_ACCEPTED',
        'DELIBERRY_ORDER_REJECTED',
        'DELIBERRY_ORDER_READY',
      ]) {
        expect(sql, contains(eventType));
      }

      expect(sql, contains('get_deliberry_operational_order_inbox'));
      expect(sql, contains('get_deliberry_operational_order_events_for_retry'));
      expect(sql, contains('deliberry_operational_transition_allowed'));
      expect(sql, contains('accept_deliberry_operational_order'));
      expect(sql, contains('reject_deliberry_operational_order'));
      expect(sql, contains('mark_deliberry_operational_order_ready'));
      expect(sql, contains('reprocess_deliberry_operational_order_event'));
      expect(sql, contains('get_deliberry_operational_reconciliation'));
      expect(sql, contains('attempt_count = attempt_count + 1'));
      expect(sql, contains('mark_deliberry_operational_event_processed'));
      expect(sql, contains('mark_deliberry_operational_event_failed'));
      expect(sql, contains('public.user_accessible_stores(auth.uid())'));
      expect(sql, contains("COALESCE(auth.role(), '') <> 'service_role'"));
      expect(
        sql,
        contains("status IN ('pending', 'failed')"),
        reason: 'Retry workers must not dispatch dead-lettered events again.',
      );
      expect(
        sql,
        contains("WHEN attempt_count + 1 >= v_dead_after_attempts THEN 'dead'"),
      );
      expect(
        sql,
        contains(
          'REVOKE EXECUTE ON FUNCTION public.apply_deliberry_operational_order_event',
        ),
      );
      expect(sql, contains(') TO service_role;'));
      expect(sql, isNot(contains('INSERT INTO public.external_sales')));
      expect(sql, isNot(contains('UPDATE public.external_sales')));
      expect(sql, isNot(contains('ALTER TABLE public.restaurants RENAME')));
      expect(sql, isNot(contains('DROP TABLE public.restaurants')));
    });

    test(
      'external webhook and dispatcher functions expose vendor boundary',
      () {
        final webhook = readRepoFile(
          'supabase/functions/deliberry-webhook/index.ts',
        );
        final dispatcher = readRepoFile(
          'supabase/functions/deliberry-dispatcher/index.ts',
        );

        expect(webhook, contains('DELIBERRY_WEBHOOK_SECRET'));
        expect(webhook, contains('x-deliberry-signature'));
        expect(webhook, contains('x-deliberry-timestamp'));
        expect(webhook, contains('DELIBERRY_WEBHOOK_REPLAY_WINDOW_SECONDS'));
        expect(webhook, contains('crypto.subtle.importKey'));
        expect(webhook, contains('receive_deliberry_operational_order'));
        expect(webhook, contains('apply_deliberry_operational_order_event'));
        expect(webhook, contains('DELIBERRY_ORDER_RECEIVED'));
        expect(webhook, contains('DELIBERRY_ORDER_DELIVERED'));
        expect(webhook, contains('DELIBERRY_ORDER_CUSTOMER_CANCELLED'));
        expect(webhook, contains('event_sequence'));
        expect(webhook, contains('trace_id'));
        expect(webhook, isNot(contains('console.log')));

        expect(dispatcher, contains('CRON_SECRET'));
        expect(dispatcher, contains('DELIBERRY_OPERATIONAL_EVENT_ENDPOINT'));
        expect(dispatcher, contains('DELIBERRY_API_BASE_URL'));
        expect(dispatcher, contains('DELIBERRY_API_TOKEN'));
        expect(dispatcher, contains('DELIBERRY_OUTBOUND_SECRET'));
        expect(
          dispatcher,
          contains('get_deliberry_operational_order_events_for_retry'),
        );
        expect(
          dispatcher,
          contains('mark_deliberry_operational_event_processed'),
        );
        expect(dispatcher, contains('mark_deliberry_operational_event_failed'));
        expect(dispatcher, contains('"x-pos-idempotency-key"'));
        expect(dispatcher, contains('DELIBERRY_ORDER_ACCEPTED'));
        expect(dispatcher, contains('DELIBERRY_ORDER_REJECTED'));
        expect(dispatcher, contains('DELIBERRY_ORDER_READY'));
        expect(dispatcher, contains('"pending", "failed"'));
        expect(dispatcher, contains('p_dead_after_attempts'));
        expect(dispatcher, isNot(contains('console.log')));
      },
    );

    test('external sale payloads classify merchant-collected offline', () {
      final byMode = DeliberryExternalSale.fromJson({
        'gross_amount': 50000,
        'order_status': 'completed',
        'is_revenue': true,
        'payload': {'settlement_collection_mode': 'merchant_collected_offline'},
      });
      final byAcknowledgment = DeliberryExternalSale.fromJson({
        'gross_amount': '70000',
        'order_status': 'completed',
        'is_revenue': true,
        'payload':
            '{"offline_collection_acknowledgment":{"acknowledged":true,'
            '"payment_method":"bank_transfer",'
            '"acknowledged_at":"2026-06-12T11:00:00+07:00",'
            '"acknowledged_by":"merchant-staff-9"}}',
      });
      final platformCollected = DeliberryExternalSale.fromJson({
        'gross_amount': 90000,
        'order_status': 'completed',
        'is_revenue': true,
        'payload': {
          'settlement_collection_mode': 'platform_collected_or_unverified',
        },
      });

      expect(byMode.isMerchantCollectedOffline, isTrue);
      expect(byMode.excludesFromPlatformPayout, isTrue);
      expect(byAcknowledgment.isMerchantCollectedOffline, isTrue);
      expect(byAcknowledgment.excludesFromPlatformPayout, isTrue);
      expect(platformCollected.isMerchantCollectedOffline, isFalse);
    });

    test(
      'settlement estimate excludes offline cash and bank transfer payout',
      () {
        final estimate = DeliberrySettlementEstimate.fromExternalSales(
          [
            DeliberryExternalSale.fromJson({
              'gross_amount': 100000,
              'order_status': 'completed',
              'is_revenue': true,
              'payload': {
                'settlement_collection_mode':
                    'platform_collected_or_unverified',
              },
            }),
            DeliberryExternalSale.fromJson({
              'gross_amount': 40000,
              'order_status': 'completed',
              'is_revenue': true,
              'payload': {
                'offline_collection_acknowledgment': {
                  'acknowledged': true,
                  'payment_method': 'cash',
                  'acknowledged_at': '2026-06-12T10:05:00+07:00',
                  'acknowledged_by': 'merchant-staff-7',
                },
              },
            }),
            DeliberryExternalSale.fromJson({
              'gross_amount': 30000,
              'order_status': 'completed',
              'is_revenue': true,
              'payload': {
                'settlement_collection_mode': 'merchant_collected_offline',
                'offline_collection_method': 'bank_transfer',
              },
            }),
            DeliberryExternalSale.fromJson({
              'gross_amount': 25000,
              'order_status': 'cancelled',
              'is_revenue': false,
              'payload': {
                'offline_collection_acknowledgment': {
                  'acknowledged': true,
                  'payment_method': 'cash',
                },
              },
            }),
          ],
          platformCommissionRate: 0.01,
          paymentFeeRate: 0.02,
        );

        expect(estimate.grossTotal, 170000);
        expect(estimate.merchantOfflineCollectionTotal, 70000);
        expect(estimate.platformPayableGross, 100000);
        expect(estimate.platformCommission, 1000);
        expect(estimate.paymentFee, 2000);
        expect(estimate.totalDeductions, 73000);
        expect(estimate.netSettlement, 97000);
      },
    );

    test(
      'delivery settlement function excludes offline collection from payout',
      () {
        final source = readRepoFile(
          'supabase/functions/generate_delivery_settlement/index.ts',
        );

        expect(
          source,
          contains(".select('restaurant_id, gross_amount, payload')"),
        );
        expect(source, contains('function isMerchantCollectedOffline'));
        expect(
          source,
          contains(
            "settlement_collection_mode === 'merchant_collected_offline'",
          ),
        );
        expect(source, contains('offline_collection_acknowledgment'));
        expect(source, contains('merchantOfflineCollection'));
        expect(source, contains('platformPayableGross'));
        expect(
          source,
          contains('(platformPayableGross * PLATFORM_COMMISSION_RATE)'),
        );
        expect(
          source,
          contains('(platformPayableGross * ESTIMATED_PAYMENT_FEE_RATE)'),
        );
        expect(source, contains("item_type: 'merchant_offline_collection'"));
        expect(source, contains('reference_base: platformPayableGross'));
      },
    );

    test('legacy generate-settlement remains idempotent for a period', () {
      final source = readRepoFile(
        'supabase/functions/generate-settlement/index.ts',
      );

      expect(source, contains('.from("delivery_settlements")'));
      expect(source, contains('.eq("source_system", "deliberry")'));
      expect(source, contains('.eq("period_label", periodLabel)'));
      expect(source, contains('SETTLEMENT_ALREADY_EXISTS'));
      expect(source, contains('.select("id, gross_amount, payload")'));
      expect(source, contains('function isMerchantCollectedOffline'));
      expect(
        source,
        contains('settlement_collection_mode === "merchant_collected_offline"'),
      );
      expect(source, contains('offline_collection_acknowledgment'));
      expect(source, contains('merchantOfflineCollection'));
      expect(source, contains('platformPayableGross'));
      expect(source, contains('Math.round(platformPayableGross * 0.015)'));
      expect(source, contains('item_type: "merchant_offline_collection"'));
      expect(source, contains('reference_base: platformPayableGross'));
    });
  });
}
