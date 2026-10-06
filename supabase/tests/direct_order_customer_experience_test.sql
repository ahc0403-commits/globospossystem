-- Synthetic requests only. The shell runner uses a disposable Docker database.
BEGIN;
DO $$ BEGIN IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF; END $$;
CREATE SCHEMA feedback_test;
CREATE FUNCTION feedback_test.assert(ok boolean,reason text) RETURNS void LANGUAGE plpgsql AS $$
BEGIN IF ok IS DISTINCT FROM true THEN RAISE EXCEPTION '%',reason; END IF; END $$;
CREATE FUNCTION feedback_test.expect_error(sql text,expected text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE actual text;
BEGIN BEGIN EXECUTE sql; EXCEPTION WHEN OTHERS THEN actual:=SQLERRM; END;
 PERFORM feedback_test.assert(actual=expected,format('EXPECTED %s GOT %s',expected,actual)); END $$;

UPDATE public.users SET role='cashier',restaurant_id='d1000000-0000-4000-8000-000000000002' WHERE auth_id=auth.uid();
DO $$
DECLARE f jsonb; rid uuid; sid uuid; secret text; rows jsonb; device uuid:=gen_random_uuid();
BEGIN
 PERFORM feedback_test.assert(public.direct_order_display_stage('awaiting_payment_review',NULL)='customer_pending','PROOF_IS_NOT_PAYMENT');
 PERFORM feedback_test.assert(public.direct_order_display_stage('approved','ready')='customer_paid','READY_IS_NOT_COMPLETE');
 PERFORM feedback_test.assert(public.direct_order_display_stage('approved','dispatched')='customer_paid','DISPATCH_IS_NOT_COMPLETE');
 PERFORM feedback_test.assert(public.direct_order_display_stage('approved','completed')='customer_completed','COMPLETION_PROJECTION');
 PERFORM feedback_test.assert(public.direct_order_display_stage('approved','cancelled')='customer_exception','FULFILLMENT_CANCEL_HIDDEN');
 PERFORM feedback_test.assert(public.direct_order_display_stage('cancelled','completed')='customer_exception','REQUEST_CANCEL_PRECEDENCE');
 f:=photo_test.create_request(true);rid:=(f->>'request_id')::uuid;
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=rid;
 SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
 INSERT INTO public.direct_order_requests(restaurant_id,session_id,client_request_id,reference_code,state)
 SELECT 'd1000000-0000-4000-8000-000000000002',sid,gen_random_uuid(),'DCF'||lpad(upper(to_hex(n)),6,'0'),'cancelled'
 FROM generate_series(1,201) n;
 rows:=public.direct_order_staff_list_v3('d1000000-0000-4000-8000-000000000002',ARRAY['customer_pending'],1);
 PERFORM feedback_test.assert(jsonb_array_length(rows)=1 AND rows->0->>'id'=rid::text,'FILTER_AFTER_LIMIT_LOSES_PENDING');
 PERFORM feedback_test.expect_error('SELECT public.direct_order_staff_list_v3(''d1000000-0000-4000-8000-000000000002'',NULL,0)','DIRECT_ORDER_LIMIT_INVALID');
 PERFORM feedback_test.expect_error('SELECT public.direct_order_staff_list_v3(''d2000000-0000-4000-8000-000000000002'',NULL,100)','DIRECT_ORDER_FORBIDDEN');
 UPDATE public.users SET role='kitchen' WHERE auth_id=auth.uid();
 PERFORM feedback_test.expect_error('SELECT public.direct_order_staff_list_v3(''d1000000-0000-4000-8000-000000000002'',NULL,100)','DIRECT_ORDER_FORBIDDEN');
 UPDATE public.users SET role='cashier' WHERE auth_id=auth.uid();
 PERFORM feedback_test.expect_error(format('SELECT public.direct_order_public_push_subscription(%L,%L,%L,%L,''ko'',true)',sid,repeat('f',64),device,repeat('token',10)),'DIRECT_ORDER_SESSION_INVALID');
 PERFORM public.direct_order_public_push_subscription(sid,secret,device,repeat('token',10),'ko',true);
 PERFORM public.direct_order_public_push_subscription(sid,secret,device,repeat('token',10),'en',true);
 PERFORM feedback_test.assert((SELECT count(*)=1 FROM public.direct_order_push_devices WHERE session_id=sid),'SUBSCRIPTION_REPLAY_DUPLICATE');
 PERFORM feedback_test.assert((SELECT locale='en' FROM public.direct_order_push_devices WHERE session_id=sid),'LOCALE_REFRESH_FAILED');
 PERFORM public.direct_order_public_push_subscription(sid,secret,device,NULL,'en',false);
 PERFORM feedback_test.assert((SELECT NOT enabled FROM public.direct_order_push_devices WHERE session_id=sid),'UNSUBSCRIBE_FAILED');
 PERFORM public.direct_order_enqueue_customer_event(rid,'pickup_ready');
 PERFORM feedback_test.assert(NOT EXISTS(SELECT 1 FROM public.direct_order_customer_events WHERE request_id=rid),'UNPAID_EVENT_CREATED');
END $$;

-- Both paperless completion and explicit Direct Kitchen changes use the trigger.
DO $$
DECLARE pickup jsonb; delivery jsonb; p uuid; d uuid; sid uuid; secret text; ticket uuid; ver integer; oid uuid;
 device uuid:=gen_random_uuid(); rows jsonb; row jsonb; wrong_lease uuid:=gen_random_uuid(); first_lease uuid;
 token_hash text; delivery_id uuid; count_before integer;
BEGIN
 pickup:=photo_test.create_request(true);p:=(pickup->>'request_id')::uuid;
 PERFORM photo_test.approve(pickup);
 UPDATE public.direct_order_requests SET fulfillment_method='pickup' WHERE id=p;
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=p;
 SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
 PERFORM public.direct_order_public_push_subscription(sid,secret,device,repeat('pickup_token',4),'ko',true);
 SELECT t.id,t.version,f.order_id INTO ticket,ver,oid FROM public.direct_delivery_fulfillment_tickets t JOIN public.direct_order_financials f ON f.request_id=t.request_id WHERE t.request_id=p;
 INSERT INTO feedback_kds_events(order_id,actor_user_id,stage,delta) VALUES(oid,(SELECT id FROM public.users WHERE auth_id=auth.uid()),'kitchen_done',1);
 PERFORM feedback_test.assert((SELECT status='preparing' FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket),'KDS_PREPARING_FAILED');
 INSERT INTO feedback_kds_events(order_id,actor_user_id,stage,delta) VALUES(oid,(SELECT id FROM public.users WHERE auth_id=auth.uid()),'tray_dispatched',1);
 PERFORM feedback_test.assert((SELECT status='ready' AND dispatched_at IS NULL FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket),'KDS_FALSE_DRIVER_HANDOFF');
 SELECT version INTO ver FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket;
 INSERT INTO feedback_kds_events(order_id,actor_user_id,stage,delta) VALUES(oid,(SELECT id FROM public.users WHERE auth_id=auth.uid()),'tray_dispatched',1);
 PERFORM feedback_test.assert((SELECT version=ver FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket),'KDS_REPLAY_INCREMENTED_VERSION');
 PERFORM feedback_test.assert((SELECT count(*)=1 FROM public.direct_order_customer_events WHERE request_id=p),'DUPLICATE_READY_EVENT');
 PERFORM feedback_test.assert((SELECT count(*)=1 FROM public.direct_order_messages WHERE request_id=p AND body='DIRECT_ORDER_PICKUP_READY'),'READY_CHAT_MISSING_OR_DUPLICATE');
 PERFORM photo_test.assert_single_graph(p);

 delivery:=photo_test.create_request(true);d:=(delivery->>'request_id')::uuid;
 PERFORM photo_test.approve(delivery);
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=d;
 SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
 PERFORM public.direct_order_public_push_subscription(sid,secret,device,repeat('driver_token',4),'vi',true);
 SELECT t.id,t.version,f.order_id INTO ticket,ver,oid FROM public.direct_delivery_fulfillment_tickets t JOIN public.direct_order_financials f ON f.request_id=t.request_id WHERE t.request_id=d;
 INSERT INTO feedback_kds_events(order_id,actor_user_id,stage,delta) VALUES(oid,(SELECT id FROM public.users WHERE auth_id=auth.uid()),'tray_dispatched',1);
 PERFORM feedback_test.assert(NOT EXISTS(SELECT 1 FROM public.direct_order_customer_events WHERE request_id=d),'PACKING_EMITTED_DELIVERY_NOTICE');
 SELECT version INTO ver FROM public.direct_delivery_fulfillment_tickets WHERE id=ticket;
 PERFORM public.direct_order_set_dispatch_v3('d1000000-0000-4000-8000-000000000002',d,ver,'be','https://be.example/fixture',NULL,NULL,'Fixture driver');
 PERFORM public.direct_order_set_dispatch_v3('d1000000-0000-4000-8000-000000000002',d,ver,'be','https://be.example/fixture',NULL,NULL,'Fixture driver');
 PERFORM feedback_test.assert((SELECT count(*)=1 FROM public.direct_order_customer_events WHERE request_id=d),'HANDOFF_REPLAY_DUPLICATE');
 PERFORM photo_test.assert_single_graph(d);

 rows:=public.claim_direct_order_push_deliveries(100);
 PERFORM feedback_test.assert(jsonb_array_length(rows)=2,'CLAIM_DID_NOT_BATCH_DEVICES');
 PERFORM feedback_test.assert(jsonb_array_length(public.claim_direct_order_push_deliveries(100))=0,'ACTIVE_LEASE_RECLAIMED');
 FOR row IN SELECT value FROM jsonb_array_elements(rows) LOOP
   delivery_id:=(row->>'id')::uuid;first_lease:=(row->>'lease_id')::uuid;token_hash:=row->>'token_hash';
   PERFORM feedback_test.assert(NOT public.complete_direct_order_push_delivery(delivery_id,wrong_lease,'sent',token_hash),'WRONG_LEASE_ACCEPTED');
   IF row->>'request_id'=p::text THEN
     PERFORM feedback_test.assert(row->>'locale'='ko','CUSTOMER_LOCALE_LOST');
     PERFORM feedback_test.assert(public.complete_direct_order_push_delivery(delivery_id,first_lease,'sent',token_hash),'SEND_ACK_FAILED');
   ELSE
     PERFORM feedback_test.assert(public.complete_direct_order_push_delivery(delivery_id,first_lease,'retry',token_hash),'RETRY_ACK_FAILED');
     PERFORM feedback_test.assert((SELECT status='pending' AND available_at>now() FROM public.direct_order_push_deliveries WHERE id=delivery_id),'RETRY_NOT_DELAYED');
     UPDATE public.direct_order_push_deliveries SET available_at=now()-interval '1 second' WHERE id=delivery_id;
     rows:=public.claim_direct_order_push_deliveries(100);
     PERFORM feedback_test.assert(jsonb_array_length(rows)=1,'SENT_DEVICE_WAS_RETRIED');
     PERFORM feedback_test.assert(NOT public.complete_direct_order_push_delivery(delivery_id,first_lease,'sent',token_hash),'STALE_LEASE_ACCEPTED');
     PERFORM feedback_test.assert(public.complete_direct_order_push_delivery(delivery_id,(rows->0->>'lease_id')::uuid,'invalid_token',token_hash),'INVALID_TOKEN_ACK_FAILED');
     PERFORM feedback_test.assert((SELECT NOT enabled FROM public.direct_order_push_devices WHERE session_id=sid AND device_id=device),'INVALID_TOKEN_NOT_DISABLED');
   END IF;
 END LOOP;
 -- Switching an already-ready delivery to pickup also emits its ready notice.
 delivery:=photo_test.create_request(true);d:=(delivery->>'request_id')::uuid;PERFORM photo_test.approve(delivery);
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=d; SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
 PERFORM public.direct_order_public_push_subscription(sid,secret,device,repeat('late_pickup_token',3),'en',true);
 UPDATE public.direct_delivery_fulfillment_tickets SET status='ready' WHERE request_id=d;
 UPDATE public.direct_order_requests SET fulfillment_method='pickup' WHERE id=d;
 PERFORM feedback_test.assert((SELECT count(*)=1 FROM public.direct_order_customer_events WHERE request_id=d),'READY_CONVERSION_NOTICE_MISSING');
 UPDATE public.direct_delivery_fulfillment_tickets SET status='completed' WHERE request_id=d;
 PERFORM feedback_test.assert(jsonb_array_length(public.claim_direct_order_push_deliveries(100))=0,'TERMINAL_ORDER_RECEIVED_STALE_NOTICE');
 PERFORM feedback_test.assert((SELECT count(*)=1 FROM public.direct_order_push_deliveries q JOIN public.direct_order_customer_events e ON e.id=q.event_id WHERE e.request_id=d AND q.status='skipped'),'TERMINAL_NOTICE_NOT_SKIPPED');
END $$;

-- Native pickup keeps its request type while the fallback method remains delivery.
DO $$
DECLARE fixture jsonb; rid uuid; oid uuid; ver integer; rows jsonb;
BEGIN
 fixture:=photo_test.create_request(true);rid:=(fixture->>'request_id')::uuid;
 UPDATE public.direct_order_requests SET fulfillment_type='pickup',created_at=now()+interval '1 second' WHERE id=rid;
 PERFORM photo_test.approve(fixture);
 SELECT order_id INTO oid FROM public.direct_order_financials WHERE request_id=rid;
 INSERT INTO feedback_kds_events(order_id,actor_user_id,stage,delta)
 VALUES(oid,(SELECT id FROM public.users WHERE auth_id=auth.uid()),'tray_dispatched',1);
 PERFORM feedback_test.assert((SELECT status='ready' FROM public.direct_delivery_fulfillment_tickets WHERE request_id=rid),'NATIVE_PICKUP_NOT_READY');
 PERFORM feedback_test.assert((SELECT count(*)=1 FROM public.direct_order_customer_events WHERE request_id=rid AND event_kind='pickup_ready'),'NATIVE_PICKUP_NOTICE_MISSING');
 rows:=public.direct_order_staff_list_v3('d1000000-0000-4000-8000-000000000002',NULL,1,'pickup');
 PERFORM feedback_test.assert(jsonb_array_length(rows)=1 AND rows->0->>'id'=rid::text AND rows->0->>'fulfillment_type'='pickup','NATIVE_PICKUP_FILTER_OR_TYPE_LOST');
 INSERT INTO feedback_kds_events(order_id,actor_user_id,stage,delta)
 VALUES(oid,(SELECT id FROM public.users WHERE auth_id=auth.uid()),'tray_dispatched',-1);
 PERFORM feedback_test.assert((SELECT status='preparing' FROM public.direct_delivery_fulfillment_tickets WHERE request_id=rid),'NATIVE_PICKUP_UNDO_LOST');
END $$;

SELECT feedback_test.assert(NOT has_table_privilege('anon','public.direct_order_push_devices','SELECT'),'PUBLIC_TOKENS_EXPOSED');
SELECT feedback_test.assert(NOT has_function_privilege('authenticated','public.claim_direct_order_push_deliveries(integer)','EXECUTE'),'STAFF_CAN_CLAIM_CUSTOMER_TOKENS');
ROLLBACK;
