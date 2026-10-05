-- Reproduce the actual paid order: pickup is approved, but has no KDS queue.
DO $$ DECLARE f jsonb; approved jsonb; definition text;
BEGIN
 definition:=pg_get_functiondef('public.direct_delivery_ticket_list(uuid,text[],timestamptz,uuid,integer)'::regprocedure);
 ASSERT position('WHERE ticket.restaurant_id = p_store_id' IN definition)>0;
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',false);
 f:=photo_test.create_request(true,'not_applicable','pickup');
 approved:=photo_test.approve(f);
 ASSERT (SELECT status='pending' FROM public.direct_delivery_fulfillment_tickets WHERE request_id=(f->>'request_id')::uuid);
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_order_queue WHERE order_id=(approved->>'order_id')::uuid);
 INSERT INTO pickup_kds_test.stranded VALUES(f,approved,pickup_kds_test.financial_hash((approved->>'order_id')::uuid));
END $$;
SELECT 'DIRECT_PICKUP_STRANDED_ORDER_REPRODUCED=PASS';
