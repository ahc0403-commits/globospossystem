-- Integration test: run after fixtures/direct_delivery_test_fixture.sql in a
-- disposable codex_direct_* database with effective production functions.
\set ON_ERROR_STOP on
BEGIN;
DO $$ BEGIN
 IF current_database() !~ '^codex_direct_' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
END $$;
-- Deterministic noon clock applies only to this rollback transaction.
DO $$ DECLARE def text; BEGIN
 def:=pg_get_functiondef('public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)'::regprocedure);
 def:=replace(def,'(now() AT TIME ZONE ''Asia/Ho_Chi_Minh'')::time','''12:00''::time'); EXECUTE def;
 def:=pg_get_functiondef('public.enforce_restaurant_daily_cutoff()'::regprocedure);
 def:=replace(def,'statement_timestamp()','((now() AT TIME ZONE ''Asia/Ho_Chi_Minh'')::date + time ''12:00'') AT TIME ZONE ''Asia/Ho_Chi_Minh'''); EXECUTE def;
END $$;

CREATE FUNCTION direct_delivery_test.create_pickup() RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE c direct_delivery_test.constants%ROWTYPE; sid uuid:=gen_random_uuid(); secret text:=repeat('a',64);
 submitted jsonb; quote jsonb; rid uuid;
BEGIN
 SELECT * INTO c FROM direct_delivery_test.constants LIMIT 1;
 INSERT INTO public.direct_order_sessions(id,restaurant_id,secret_hash,locale) VALUES(sid,c.store_id,secret,'ko');
 submitted:=public.direct_order_public_submit_v2(sid,secret,gen_random_uuid(),jsonb_build_object(
  'fulfillment_type','pickup','locale','ko',
  'items',jsonb_build_array(jsonb_build_object('menu_item_id',c.menu_item_id,'quantity',1)),
  'address',jsonb_build_object('customer_name','Pickup Customer','customer_phone','0901234567','address_source','pickup')));
 rid:=(submitted->>'request_id')::uuid;
 PERFORM direct_delivery_test.set_actor();
 BEGIN PERFORM public.direct_order_staff_quote_with_payment_mode(c.store_id,rid,25000,NULL,'store_prepaid');
  RAISE EXCEPTION 'PICKUP_FEE_WAS_ACCEPTED'; EXCEPTION WHEN OTHERS THEN
  IF SQLERRM <> 'DIRECT_ORDER_PICKUP_FEE_INVALID' THEN RAISE; END IF; END;
 BEGIN PERFORM public.direct_order_staff_quote(c.store_id,rid,25000,NULL);
  RAISE EXCEPTION 'LEGACY_PICKUP_FEE_WAS_ACCEPTED'; EXCEPTION WHEN OTHERS THEN
  IF SQLERRM <> 'DIRECT_ORDER_PICKUP_FEE_INVALID' THEN RAISE; END IF; END;
 BEGIN UPDATE public.direct_order_requests SET fulfillment_type='delivery' WHERE id=rid;
  RAISE EXCEPTION 'PICKUP_TYPE_CHANGED'; EXCEPTION WHEN OTHERS THEN
  IF SQLERRM <> 'DIRECT_ORDER_FULFILLMENT_TYPE_LOCKED' THEN RAISE; END IF; END;
 quote:=public.direct_order_staff_quote_with_payment_mode(c.store_id,rid,0,NULL,'not_applicable');
 PERFORM public.direct_order_public_commit_proof(sid,secret,rid,c.store_id::text||'/'||rid::text||'/'||gen_random_uuid()::text||'.jpg');
 RETURN submitted||jsonb_build_object('final_total',quote->'final_total','session_id',sid,'secret',secret);
END $$;

DO $$
DECLARE c direct_delivery_test.constants%ROWTYPE; req jsonb; approved jsonb; rid uuid; oid uuid;
 ticket public.direct_delivery_fulfillment_tickets%ROWTYPE; response jsonb; ordinary uuid;
BEGIN
 SELECT * INTO c FROM direct_delivery_test.constants LIMIT 1;
 PERFORM direct_delivery_test.set_actor();
 -- A paperless store must still keep direct pickups off the dine-in/floor queue.
 UPDATE public.restaurant_settings SET fulfillment_mode='paperless' WHERE restaurant_id=c.store_id;
 INSERT INTO public.emergency_fulfillment_sessions(restaurant_id,status,activated_by,reason)
 VALUES(c.store_id,'active',c.user_id,'pickup isolation regression');
 req:=direct_delivery_test.create_pickup(); rid:=(req->>'request_id')::uuid;
 ASSERT (SELECT fulfillment_type='pickup' FROM public.direct_order_requests WHERE id=rid);
 ASSERT (SELECT formatted_address IS NULL AND detail_address IS NULL AND latitude IS NULL AND longitude IS NULL FROM public.direct_order_request_addresses WHERE request_id=rid);
 BEGIN PERFORM public.direct_order_staff_quote_with_payment_mode(c.store_id,rid,25000,NULL,'store_prepaid');
  RAISE EXCEPTION 'PICKUP_FEE_WAS_ACCEPTED'; EXCEPTION WHEN OTHERS THEN
  IF SQLERRM NOT IN ('DIRECT_ORDER_PICKUP_FEE_INVALID','DIRECT_ORDER_REQUEST_NOT_QUOTABLE') THEN RAISE; END IF; END;
 approved:=direct_delivery_test.approve(rid,(req->>'final_total')::numeric); oid:=(approved->>'order_id')::uuid;
 PERFORM direct_delivery_test.assert_single_graph(rid);
 ASSERT (SELECT sales_channel='takeaway' AND status='completed' FROM public.orders WHERE id=oid);
 ASSERT (SELECT delivery_payment_mode='not_applicable' AND delivery_fee_total=0 FROM public.direct_order_financials WHERE request_id=rid);
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_order_queue WHERE order_id=oid);
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_fulfillment_items WHERE order_id=oid);
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_floor_direct_items WHERE order_id=oid);
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_combo_component_items WHERE order_id=oid);
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_fulfillment_events WHERE order_id=oid);
 ASSERT COALESCE(current_setting('app.direct_order_pos_id',true),'')='';
 ASSERT COALESCE(current_setting('app.direct_order_request_id',true),'')='';
 ASSERT (SELECT bool_and(fulfillment_mode_snapshot='paperless') FROM public.order_items WHERE order_id=oid);
 ASSERT EXISTS(SELECT 1 FROM public.print_jobs WHERE order_id=oid AND copy_type='receipt' AND payload->>'direct_fulfillment_type'='pickup' AND payload->>'direct_delivery_payment_mode'='not_applicable');
 ASSERT (public.direct_order_public_status_v3((req->>'session_id')::uuid,req->>'secret',rid)->>'fulfillment_type')='pickup';
 ASSERT NOT (public.direct_order_public_status_v2((req->>'session_id')::uuid,req->>'secret',rid) ? 'fulfillment_type');
 BEGIN PERFORM public.direct_order_set_dispatch_with_payment_mode(c.store_id,rid,'https://grab.com/test',0); RAISE EXCEPTION 'PICKUP_DISPATCH_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'DIRECT_ORDER_PICKUP_DISPATCH_FORBIDDEN' THEN RAISE; END IF; END;
 SELECT * INTO ticket FROM public.direct_delivery_fulfillment_tickets WHERE request_id=rid;
 BEGIN PERFORM public.direct_order_cashier_complete_pickup(c.store_id,rid,ticket.version); RAISE EXCEPTION 'UNREADY_PICKUP_COMPLETED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'DIRECT_ORDER_PICKUP_NOT_READY' THEN RAISE; END IF; END;
 PERFORM public.direct_delivery_ticket_transition(c.store_id,ticket.id,ticket.version,'preparing');
 SELECT * INTO ticket FROM public.direct_delivery_fulfillment_tickets WHERE request_id=rid;
 PERFORM public.direct_delivery_ticket_transition(c.store_id,ticket.id,ticket.version,'ready');
 SELECT * INTO ticket FROM public.direct_delivery_fulfillment_tickets WHERE request_id=rid;
 BEGIN PERFORM public.direct_order_cashier_complete_pickup(c.store_id,rid,ticket.version-1); RAISE EXCEPTION 'STALE_PICKUP_COMPLETED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM <> 'DIRECT_DELIVERY_TICKET_VERSION_CONFLICT' THEN RAISE; END IF; END;
 response:=public.direct_order_cashier_complete_pickup(c.store_id,rid,ticket.version);
 ASSERT response->>'status'='completed';
 ASSERT (public.direct_order_cashier_complete_pickup(c.store_id,rid,ticket.version)->>'idempotent')::boolean;
 ASSERT (SELECT count(*)=1 FROM public.audit_logs WHERE entity_id=rid AND action='direct_order_pickup_completed');
 -- Negative control: ordinary takeaway must still enter its existing KDS route.
 INSERT INTO public.orders(restaurant_id,sales_channel,status,order_source,order_purpose)
 VALUES(c.store_id,'takeaway','serving','staff','customer') RETURNING id INTO ordinary;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,item_type,label,display_name,unit_price,quantity,status)
 VALUES(c.store_id,ordinary,c.menu_item_id,'menu_item','Ordinary','Ordinary',100000,1,'pending');
 ASSERT EXISTS(SELECT 1 FROM public.emergency_order_queue WHERE order_id=ordinary);
 ASSERT EXISTS(SELECT 1 FROM public.emergency_fulfillment_items WHERE order_id=ordinary);
END $$;
DO $$
DECLARE c direct_delivery_test.constants%ROWTYPE; req jsonb; rid uuid; quote jsonb; approved jsonb; mode text; fee numeric;
BEGIN
 SELECT * INTO c FROM direct_delivery_test.constants LIMIT 1;
 PERFORM direct_delivery_test.set_actor();
 UPDATE public.restaurant_settings SET fulfillment_mode='pos_print' WHERE restaurant_id=c.store_id;
 FOREACH mode IN ARRAY ARRAY['customer_direct','store_prepaid'] LOOP
  req:=direct_delivery_test.create_request('awaiting_quote'); rid:=(req->>'request_id')::uuid;
  fee:=CASE WHEN mode='store_prepaid' THEN 25000 ELSE 0 END;
  ASSERT (SELECT fulfillment_type='delivery' FROM public.direct_order_requests WHERE id=rid);
  quote:=public.direct_order_staff_quote_with_payment_mode(c.store_id,rid,fee,NULL,mode);
  PERFORM public.direct_order_public_commit_proof((req->>'session_id')::uuid,req->>'secret_hash',rid,
    c.store_id::text||'/'||rid::text||'/'||gen_random_uuid()::text||'.jpg');
  approved:=direct_delivery_test.approve(rid,(quote->>'final_total')::numeric);
  PERFORM direct_delivery_test.assert_single_graph(rid);
  ASSERT (SELECT sales_channel='delivery' FROM public.orders WHERE id=(approved->>'order_id')::uuid);
  ASSERT (SELECT delivery_payment_mode=mode AND delivery_fee_total=fee FROM public.direct_order_financials WHERE request_id=rid);
  ASSERT EXISTS(SELECT 1 FROM public.print_jobs WHERE order_id=(approved->>'order_id')::uuid AND copy_type='receipt'
    AND payload->>'direct_fulfillment_type'='delivery' AND payload->>'direct_delivery_payment_mode'=mode);
 END LOOP;
 ASSERT NOT has_function_privilege('anon','public.direct_order_public_submit_v2(uuid,text,uuid,jsonb)','EXECUTE');
 ASSERT NOT has_function_privilege('authenticated','public.direct_order_public_status_v3(uuid,text,uuid)','EXECUTE');
 ASSERT NOT has_function_privilege('anon','public.direct_order_cashier_complete_pickup(uuid,uuid,integer)','EXECUTE');
END $$;
SELECT 'DIRECT_ORDER_PICKUP_INTEGRATION=PASS';
SELECT 'DIRECT_ORDER_DELIVERY_PAYMENT_MODES=PASS';
ROLLBACK;
