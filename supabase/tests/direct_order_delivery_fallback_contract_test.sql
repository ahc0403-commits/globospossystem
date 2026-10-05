-- Runs only inside the isolated fixture built by the fallback shell runner.
BEGIN;
CREATE SCHEMA fallback_test;
CREATE FUNCTION fallback_test.assert(p_ok boolean,p_message text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF p_ok IS DISTINCT FROM true THEN RAISE EXCEPTION '%',p_message; END IF; END $$;
CREATE FUNCTION fallback_test.expect_error(p_sql text,p_error text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual text;
BEGIN BEGIN EXECUTE p_sql; EXCEPTION WHEN OTHERS THEN actual:=SQLERRM; END;
 PERFORM fallback_test.assert(actual=p_error,format('EXPECTED %s, GOT %s',p_error,actual)); END $$;

DO $$
DECLARE f jsonb; sid uuid; secret text; rid uuid; oid uuid; other_session uuid; old_offer uuid; ctx jsonb; result jsonb; client uuid; payload jsonb;
  store uuid:='d1000000-0000-4000-8000-000000000002'; total numeric; before_stock numeric; ticket uuid; ticket_version integer;
BEGIN
 PERFORM fallback_test.assert(public.direct_order_tracking_url_valid('https://be.example/track/abc'),'BE_URL_REJECTED');
 PERFORM fallback_test.assert(NOT public.direct_order_tracking_url_valid('javascript:alert(1)'),'UNSAFE_URL_ACCEPTED');
 PERFORM fallback_test.assert(NOT public.direct_order_tracking_url_valid('https://grab.com.evil@bad.test/'),'URL_CREDENTIALS_ACCEPTED');
 INSERT INTO public.direct_order_sessions(restaurant_id,secret_hash,locale) VALUES(store,repeat('a',64),'vi') RETURNING id INTO sid;
 payload:=jsonb_build_object('locale','vi','diner_count',3,'items',jsonb_build_array(jsonb_build_object('menu_item_id','d1000000-0000-4000-8000-000000000003','quantity',1)),
   'address',jsonb_build_object('customer_name','Test','customer_phone','0901234567','formatted_address','123 Test Street','detail_address','Door 1','address_source','manual','location_verified',false));
 FOR total IN SELECT value FROM unnest(ARRAY[0,-1,101,1.5]) value LOOP
  PERFORM fallback_test.expect_error(format('SELECT public.direct_order_public_submit_v3(%L,%L,%L,%L)',sid,repeat('a',64),gen_random_uuid(),jsonb_set(payload,'{diner_count}',to_jsonb(total))),'DIRECT_ORDER_DINER_COUNT_INVALID');
 END LOOP;
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_public_submit_v3(%L,%L,%L,%L)',sid,repeat('a',64),gen_random_uuid(),payload-'diner_count'),'DIRECT_ORDER_DINER_COUNT_INVALID');
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_public_submit_v3(%L,%L,%L,%L)',sid,repeat('a',64),gen_random_uuid(),jsonb_set(payload,'{diner_count}','"3"')),'DIRECT_ORDER_DINER_COUNT_INVALID');
 client:=gen_random_uuid(); result:=public.direct_order_public_submit_v3(sid,repeat('a',64),client,payload);rid:=(result->>'request_id')::uuid;
 PERFORM fallback_test.assert((SELECT diner_count=3 FROM public.direct_order_requests WHERE id=rid),'DINER_COUNT_NOT_STORED');
 UPDATE public.direct_order_storefronts SET is_paused=true WHERE restaurant_id=store;
 result:=public.direct_order_public_submit_v3(sid,repeat('a',64),client,payload-'diner_count');
 PERFORM fallback_test.assert((result->>'idempotent')::boolean AND (result->>'request_id')::uuid=rid,'PAUSED_REPLAY_LOST');
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_public_submit_v3(%L,%L,%L,%L)',sid,repeat('a',64),gen_random_uuid(),payload),'DIRECT_ORDER_STOREFRONT_PAUSED');
 PERFORM fallback_test.expect_error(format('UPDATE public.direct_order_storefronts SET is_enabled=false WHERE restaurant_id=%L',store),'DIRECT_ORDER_ACTIVE_REQUESTS_EXIST');
 -- Existing orders continue while intake is paused. An unpaid pickup gets a new quote.
 ctx:=public.direct_order_staff_set_diner_count(store,rid,1,5);
 PERFORM fallback_test.assert((ctx->>'diner_count')::integer=5 AND (ctx->>'version')::integer=2,'STAFF_DINER_CORRECTION_LOST');
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_staff_set_diner_count(%L,%L,1,6)',store,rid),'DIRECT_ORDER_FULFILLMENT_CHANGED');
 PERFORM public.direct_order_staff_quote_with_payment_mode(store,rid,21600,NULL,'store_prepaid');
 ctx:=public.direct_order_staff_offer_pickup(store,rid,2,'All providers have no driver');oid:=(ctx->'pickup_offer'->>'id')::uuid;
 INSERT INTO public.direct_order_sessions(restaurant_id,secret_hash,locale) VALUES(store,repeat('c',64),'en') RETURNING id INTO other_session;
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_public_decide_pickup(%L,%L,%L,%L,true,false)',other_session,repeat('c',64),rid,oid),'DIRECT_ORDER_REQUEST_NOT_FOUND');
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_staff_offer_pickup(%L,%L,2,''No driver'')',gen_random_uuid(),rid),'DIRECT_ORDER_FORBIDDEN');
 UPDATE public.users SET role='kitchen' WHERE auth_id=auth.uid();
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_staff_offer_pickup(%L,%L,2,''No driver'')',store,rid),'DIRECT_ORDER_FORBIDDEN');
 UPDATE public.users SET role='cashier' WHERE auth_id=auth.uid();
 -- A changed quote invalidates the previous offer; staff can replace it.
 PERFORM public.direct_order_staff_quote_with_payment_mode(store,rid,25000,NULL,'store_prepaid');
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_public_decide_pickup(%L,%L,%L,%L,true,false)',sid,repeat('a',64),rid,oid),'DIRECT_ORDER_FULFILLMENT_CHANGED');
 old_offer:=oid;ctx:=public.direct_order_staff_offer_pickup(store,rid,2,'All providers have no driver');oid:=(ctx->'pickup_offer'->>'id')::uuid;
 PERFORM fallback_test.assert(oid<>old_offer,'STALE_QUOTE_OFFER_NOT_REPLACED');
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_public_decide_pickup(%L,%L,%L,%L,true,false)',sid,repeat('b',64),rid,oid),'DIRECT_ORDER_SESSION_INVALID');
 ctx:=public.direct_order_public_decide_pickup(sid,repeat('a',64),rid,oid,true,false);
 PERFORM fallback_test.assert(ctx->>'method'='pickup' AND (SELECT state='awaiting_quote' FROM public.direct_order_requests WHERE id=rid),'UNPAID_PICKUP_NOT_REQUOTED');
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_staff_quote_with_payment_mode(%L,%L,20000,NULL,''store_prepaid'')',store,rid),'DIRECT_ORDER_PICKUP_FEE_INVALID');
 PERFORM public.direct_order_staff_quote_with_payment_mode(store,rid,0,NULL,'customer_direct');
 result:=public.direct_order_public_status_v3(sid,repeat('a',64),rid);
 PERFORM fallback_test.assert(result->'delivery'->>'method'='pickup' AND result->'quote'->>'delivery_fee_total'='0.00','PICKUP_QUOTE_FEE');
 PERFORM fallback_test.assert(NOT (public.direct_order_public_status_v2(sid,repeat('a',64),rid) ? 'delivery'),'V2_RESPONSE_CHANGED');

 -- Approved original payment is retained; only the delivery fee is refunded.
 f:=photo_test.create_request(true,'store_prepaid');rid:=(f->>'request_id')::uuid;
 UPDATE public.direct_order_requests SET diner_count=4 WHERE id=rid;
 UPDATE public.direct_order_quotes SET delivery_fee_pretax=20000,delivery_fee_vat=1600,delivery_fee_total=21600,final_total=129600 WHERE id=(f->>'quote_id')::uuid;
 SELECT current_stock INTO before_stock FROM public.inventory_items LIMIT 1;
 result:=public.direct_order_approve_photo_payment(store,rid,129600,(f->>'quote_id')::uuid,(f->>'proof_id')::uuid);
 PERFORM fallback_test.assert((SELECT guest_count=4 FROM public.orders WHERE id=(result->>'order_id')::uuid),'APPROVAL_GUEST_COUNT_MISSING');
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=rid; SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
 ctx:=public.direct_order_staff_offer_pickup(store,rid,1,'No nearby driver');oid:=(ctx->'pickup_offer'->>'id')::uuid;
 ctx:=public.direct_order_public_decide_pickup(sid,secret,rid,oid,true,true);
 ctx:=public.direct_order_public_decide_pickup(sid,secret,rid,oid,true,true);
 PERFORM fallback_test.assert((SELECT count(*)=1 FROM public.direct_order_messages WHERE request_id=rid AND body='DIRECT_ORDER_PICKUP_ACCEPTED'),'DUPLICATE_CONSENT');
 SELECT id,version INTO ticket,ticket_version FROM public.direct_delivery_fulfillment_tickets WHERE request_id=rid;
 PERFORM public.direct_delivery_ticket_transition(store,ticket,ticket_version,'preparing');
 PERFORM public.direct_delivery_ticket_transition(store,ticket,ticket_version+1,'ready');
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_set_dispatch_v3(%L,%L,3,''be'',''https://be.example/track'',10000)',store,rid),'DIRECT_ORDER_PICKUP_NOT_ALLOWED');
 PERFORM public.direct_order_cashier_complete_pickup(store,rid,3);
 PERFORM public.direct_order_cashier_complete_pickup(store,rid,3);
 -- A completed pickup remains in the cashier queue across days until refund.
 UPDATE public.direct_order_requests SET created_at=now()-interval '2 days' WHERE id=rid;
 result:=public.direct_order_staff_list_v2(store,NULL,200);
 PERFORM fallback_test.assert(EXISTS(SELECT 1 FROM jsonb_array_elements(result) x WHERE x->>'id'=rid::text),'PENDING_REFUND_HIDDEN');
 -- Inject a ledger failure and verify the surrounding operation rolls back.
 CREATE FUNCTION fallback_test.reject_adjustment() RETURNS trigger LANGUAGE plpgsql AS $fault$ BEGIN RAISE EXCEPTION 'INJECTED_REFUND_FAILURE'; END $fault$;
 CREATE TRIGGER reject_adjustment BEFORE INSERT ON public.payment_adjustments FOR EACH ROW EXECUTE FUNCTION fallback_test.reject_adjustment();
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_staff_record_pickup_refund(%L,%L,%L,''failed-bank-ref'')',store,rid,oid),'INJECTED_REFUND_FAILURE');
 PERFORM fallback_test.assert((SELECT adjustment_id IS NULL FROM public.direct_order_pickup_offers WHERE request_id=rid),'FAILED_REFUND_MARKED_COMPLETE');
 DROP TRIGGER reject_adjustment ON public.payment_adjustments;
 ctx:=public.direct_order_staff_record_pickup_refund(store,rid,oid,'bank-ref-1');
 ctx:=public.direct_order_staff_record_pickup_refund(store,rid,oid,'bank-ref-1');
 PERFORM fallback_test.assert((ctx->>'refunded_total')::numeric=21600 AND (ctx->>'paid_total')::numeric=129600,'REFUND_NET_AMOUNT_WRONG');
 PERFORM fallback_test.assert((SELECT count(*)=1 FROM public.payment_adjustments WHERE payment_id=(SELECT payment_id FROM public.direct_order_financials WHERE request_id=rid)),'DUPLICATE_REFUND');
 PERFORM fallback_test.assert((SELECT current_stock=before_stock-10 FROM public.inventory_items LIMIT 1),'PICKUP_OR_REFUND_CHANGED_STOCK');
 PERFORM fallback_test.assert((SELECT count(*)=1 FROM public.direct_delivery_fulfillment_tickets WHERE request_id=rid),'PICKUP_DUPLICATE_TICKET');
 result:=public.direct_delivery_ticket_list_v3(store,NULL,100);
 PERFORM fallback_test.assert(EXISTS(SELECT 1 FROM jsonb_array_elements(result) x WHERE x->>'request_id'=rid::text AND x->'delivery'->>'method'='pickup' AND x->'delivery'->>'diner_count'='4'),'KITCHEN_PACKING_CONTEXT_LOST');
 INSERT INTO public.print_jobs(order_id,restaurant_id,payload) SELECT order_id,store,'{}'::jsonb FROM public.direct_order_financials WHERE request_id=rid;
 PERFORM fallback_test.assert((SELECT pj.payload->>'diner_count'='4' AND pj.payload->>'fulfillment_method'='pickup' AND (pj.payload->>'refunded_total')::numeric=21600 FROM public.print_jobs pj LIMIT 1),'PRINT_CONTEXT_NOT_ENRICHED');

 -- BE and linkless providers work; replay does not duplicate money or messages.
 f:=photo_test.create_request();rid:=(f->>'request_id')::uuid;result:=photo_test.approve(f);
 SELECT id,version INTO ticket,ticket_version FROM public.direct_delivery_fulfillment_tickets WHERE request_id=rid;
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_set_dispatch_v3(%L,%L,1,''be'',''https://be.example/track'')',store,rid),'DIRECT_DELIVERY_TICKET_TRANSITION_INVALID');
 PERFORM public.direct_delivery_ticket_transition(store,ticket,1,'preparing');PERFORM public.direct_delivery_ticket_transition(store,ticket,2,'ready');
 ctx:=public.direct_order_set_dispatch_v3(store,rid,3,'be','https://be.example/track');
 ctx:=public.direct_order_set_dispatch_v3(store,rid,3,'be','https://be.example/track');
 PERFORM fallback_test.assert(ctx->>'provider'='be' AND (SELECT count(*)=1 FROM public.direct_order_messages WHERE request_id=rid AND body='DIRECT_ORDER_DRIVER_HANDOFF'),'BE_REPLAY_DUPLICATED');
 PERFORM fallback_test.assert((SELECT actual_grab_fee IS NULL AND cash_paid_at IS NULL FROM public.direct_order_dispatches WHERE request_id=rid),'CUSTOMER_DIRECT_CREATED_CASH_PAYOUT');
 f:=photo_test.create_request();rid:=(f->>'request_id')::uuid;result:=photo_test.approve(f);
 SELECT id INTO ticket FROM public.direct_delivery_fulfillment_tickets WHERE request_id=rid;
 PERFORM public.direct_delivery_ticket_transition(store,ticket,1,'preparing');PERFORM public.direct_delivery_ticket_transition(store,ticket,2,'ready');
 ctx:=public.direct_order_set_dispatch_v3(store,rid,3,'other',NULL,NULL,'Local courier','0901234567');
 PERFORM fallback_test.assert(ctx->>'driver_contact'='0901234567','LINKLESS_CONTACT_LOST');
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=rid;SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
 result:=public.direct_order_public_status_v3(sid,secret,rid);
 PERFORM fallback_test.assert(result->'dispatch'='null'::jsonb AND result->'delivery'->>'provider'='other','LINKLESS_PUBLIC_RESPONSE_INVALID');
 PERFORM fallback_test.assert(public.direct_order_public_status_v2(sid,secret,rid)->'dispatch'='null'::jsonb,'LINKLESS_BROKE_LEGACY_CLIENT');

 -- Consent before payment review preserves the already transferred quote/proof.
 f:=photo_test.create_request(true,'store_prepaid');rid:=(f->>'request_id')::uuid;
 UPDATE public.direct_order_quotes SET delivery_fee_pretax=20000,delivery_fee_vat=1600,delivery_fee_total=21600,final_total=129600 WHERE id=(f->>'quote_id')::uuid;
 UPDATE public.direct_order_requests SET state='quoted' WHERE id=rid;
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=rid; SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
 ctx:=public.direct_order_staff_offer_pickup(store,rid,1,'No driver');oid:=(ctx->'pickup_offer'->>'id')::uuid;
 ctx:=public.direct_order_public_decide_pickup(sid,secret,rid,oid,true,true);
 PERFORM fallback_test.assert((SELECT state='quoted' FROM public.direct_order_requests WHERE id=rid) AND (SELECT status='locked' FROM public.direct_order_quotes WHERE id=(f->>'quote_id')::uuid),'TRANSFERRED_PICKUP_LOST_ORIGINAL_QUOTE');
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_staff_quote_with_payment_mode(%L,%L,0,NULL,''customer_direct'')',store,rid),'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED');
 UPDATE public.direct_order_requests SET state='awaiting_payment_review' WHERE id=rid;
 result:=public.direct_order_approve_photo_payment(store,rid,129600,(f->>'quote_id')::uuid,(f->>'proof_id')::uuid);
 PERFORM fallback_test.assert(result->>'payment_id' IS NOT NULL,'PICKUP_ORIGINAL_PROOF_APPROVAL_FAILED');
 ctx:=public.direct_order_fulfillment_context(rid);
 PERFORM fallback_test.assert((ctx->'pickup_offer'->>'refund_due')::numeric=21600,'TRANSFERRED_PICKUP_REFUND_DUE_LOST');
 -- Valid existing customers can restore a legacy-disabled storefront.
 ALTER TABLE public.direct_order_storefronts DISABLE TRIGGER direct_order_guard_storefront_disable;
 UPDATE public.direct_order_storefronts SET is_enabled=false WHERE restaurant_id=store;
 ALTER TABLE public.direct_order_storefronts ENABLE TRIGGER direct_order_guard_storefront_disable;
 result:=public.direct_order_public_resume_storefront(sid,secret);
 PERFORM fallback_test.assert((result->>'paused')::boolean AND result->>'store_id'=store::text AND jsonb_array_length(result->'items')=0,'DISABLED_EXISTING_SESSION_NOT_RECOVERABLE');
 PERFORM fallback_test.expect_error(format('SELECT public.direct_order_public_resume_storefront(%L,%L)',other_session,repeat('c',64)),'DIRECT_ORDER_STOREFRONT_NOT_FOUND');
 -- Ownership/least privilege and refunded analytics.
 PERFORM fallback_test.assert(NOT has_function_privilege('authenticated','public.direct_order_public_decide_pickup(uuid,text,uuid,uuid,boolean,boolean)','EXECUTE'),'PUBLIC_MUTATION_PRIVILEGE_LEAK');
 PERFORM fallback_test.assert(NOT has_function_privilege('anon','public.direct_order_staff_offer_pickup(uuid,uuid,integer,text)','EXECUTE'),'STAFF_PRIVILEGE_LEAK');
 UPDATE public.users SET role='admin' WHERE auth_id=auth.uid();
 result:=public.direct_order_analytics_v3(store,current_date-1,current_date+1);
 PERFORM fallback_test.assert((result->'summary'->>'refund_total')::numeric=21600,'REFUND_NOT_IN_ANALYTICS');
END $$;
ROLLBACK;
\echo DIRECT_ORDER_DELIVERY_FALLBACK_BEHAVIOR=PASS
