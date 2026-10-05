DO $$
DECLARE consent_id uuid; dispatch_id uuid; mixed_id uuid;
BEGIN
 SELECT (fixture->>'request_id')::uuid INTO consent_id FROM fallback_test.races WHERE operation='consent';
 SELECT (fixture->>'request_id')::uuid INTO dispatch_id FROM fallback_test.races WHERE operation='dispatch';
 SELECT (fixture->>'request_id')::uuid INTO mixed_id FROM fallback_test.races WHERE operation='offer_dispatch';
 IF (SELECT count(*) FROM public.direct_order_messages WHERE request_id=consent_id AND body='DIRECT_ORDER_PICKUP_ACCEPTED')<>1
 OR (SELECT count(*) FROM public.payment_adjustments WHERE payment_id=(SELECT payment_id FROM public.direct_order_financials WHERE request_id=consent_id))<>1
 OR (SELECT count(*) FROM public.direct_order_dispatches WHERE request_id=dispatch_id)<>1
 OR (SELECT count(*) FROM public.direct_order_messages WHERE request_id=dispatch_id AND body='DIRECT_ORDER_DRIVER_HANDOFF')<>1
 OR (SELECT count(*) FROM public.audit_logs WHERE entity_id=dispatch_id AND action='direct_order_driver_handoff')<>1
 OR (EXISTS(SELECT 1 FROM public.direct_order_pickup_offers WHERE request_id=mixed_id) = EXISTS(SELECT 1 FROM public.direct_order_dispatches WHERE request_id=mixed_id))
 THEN RAISE EXCEPTION 'CONCURRENT_FALLBACK_DUPLICATED_SIDE_EFFECTS'; END IF;
END $$;
\echo DIRECT_ORDER_DELIVERY_FALLBACK_CONCURRENCY=PASS
