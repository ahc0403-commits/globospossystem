DO $recipient$
DECLARE f jsonb;r uuid;shop uuid;ticket uuid;version integer;b jsonb;op uuid:=gen_random_uuid();booking_payload jsonb;
 q uuid;o uuid;sid uuid;secret text;path text;mid uuid;v jsonb;legacy record;
BEGIN
 SELECT * INTO legacy FROM recipient_measurement.legacy;
 IF legacy.financial IS DISTINCT FROM (SELECT to_jsonb(x) FROM public.direct_order_financials x WHERE x.request_id=legacy.request_id)
 OR legacy.quote IS DISTINCT FROM (SELECT to_jsonb(x) FROM public.direct_order_quotes x WHERE x.request_id=legacy.request_id)
 OR legacy.snapshot IS DISTINCT FROM (SELECT snapshot FROM public.digital_receipts WHERE id=legacy.receipt_id)
 THEN RAISE EXCEPTION 'RECIPIENT_CHANGED_ISSUED_HISTORY'; END IF;
 f:=photo_test.create_request(true,'customer_direct');r:=(f->>'request_id')::uuid;shop:=(f->>'store_id')::uuid;
 UPDATE public.users SET restaurant_id=shop WHERE auth_id=auth.uid();
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=r;
 SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
 IF (SELECT delivery_policy_version FROM public.direct_order_requests WHERE id=r)<>2 THEN RAISE EXCEPTION 'RECIPIENT_DEFAULT_FAILED'; END IF;
 PERFORM public.direct_order_staff_quote_with_payment_mode(shop,r,0,NULL);
 RAISE NOTICE 'RECIPIENT_QUOTE_OMITTED_MODE=PASS';
 BEGIN
  UPDATE public.direct_order_requests SET delivery_policy_version=1 WHERE id=r; RAISE EXCEPTION 'POLICY_DOWNGRADE_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_DELIVERY_POLICY_LOCKED' THEN RAISE; END IF; END;
 BEGIN
  PERFORM public.direct_order_staff_quote_with_payment_mode(shop,r,10000,NULL,'store_prepaid'); RAISE EXCEPTION 'OLD_QUOTE_ALLOWED_PREPAY';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_RECIPIENT_PAYMENT_REQUIRED' THEN RAISE; END IF; END;
 BEGIN
  INSERT INTO public.direct_order_payment_charges(request_id,restaurant_id,kind,amount,reason,status,created_by)
  VALUES(r,shop,'delivery',10000,'unsupported','pending',auth.uid()); RAISE EXCEPTION 'DELIVERY_CHARGE_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_RECIPIENT_PAYMENT_REQUIRED' THEN RAISE; END IF; END;
 -- General customer PDFs work with no charge and do not touch payment review.
 path:=shop::text||'/'||r::text||'/'||gen_random_uuid()::text||'.pdf';
 v:=public.direct_order_commit_chat_attachment(r,shop,'customer',NULL,path,'map.pdf','application/pdf');mid:=(v->>'message_id')::uuid;
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_messages WHERE id=mid AND message_type='attachment' AND metadata->>'attachment_kind'='chat')
 OR EXISTS(SELECT 1 FROM public.direct_order_payment_receipts WHERE request_id=r) THEN RAISE EXCEPTION 'GENERAL_ATTACHMENT_BECAME_PAYMENT'; END IF;
 IF public.direct_order_commit_chat_attachment(r,shop,'customer',NULL,path,'map.pdf','application/pdf')<>v THEN RAISE EXCEPTION 'CHAT_RETRY_DUPLICATED'; END IF;
 BEGIN
  PERFORM public.direct_order_commit_chat_attachment(r,shop,'cashier',auth.uid(),path,'map.pdf','application/pdf'); RAISE EXCEPTION 'CHAT_RETRY_ACTOR_CHANGED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_ATTACHMENT_INVALID' THEN RAISE; END IF; END;
 INSERT INTO storage.objects(bucket_id,name,created_at) VALUES('direct-order-chat',path,now()-interval '2 days'),
 ('direct-order-chat',shop::text||'/'||r::text||'/'||gen_random_uuid()::text||'.pdf',now()-interval '2 days');
 IF jsonb_array_length(public.direct_order_orphan_chat_candidates(100))<>1
 OR public.direct_order_orphan_chat_candidates(100) @> jsonb_build_array(path) THEN RAISE EXCEPTION 'CHAT_ORPHAN_CLEANUP_LOST_COMMITTED_FILE'; END IF;
 PERFORM photo_test.approve(f);SELECT order_id INTO o FROM public.direct_order_financials WHERE request_id=r;
 IF NOT EXISTS(SELECT 1 FROM public.print_jobs WHERE order_id=o AND payload->>'delivery_payment_mode'='customer_direct'
 AND payload->>'receipt_payload_version'='2') THEN RAISE EXCEPTION 'RECEIPT_POLICY_NOT_SNAPSHOTTED'; END IF;
 INSERT INTO public.digital_receipts(restaurant_id,order_id,snapshot) VALUES(shop,o,jsonb_build_object('order_id',o,'items','[]'::jsonb));
 IF (SELECT snapshot->>'delivery_payment_mode' FROM public.digital_receipts WHERE order_id=o)<>'customer_direct' THEN RAISE EXCEPTION 'DIGITAL_POLICY_MISSING'; END IF;
 SELECT t.id,t.version INTO ticket,version FROM public.direct_delivery_fulfillment_tickets t WHERE request_id=r;
 booking_payload:=jsonb_build_object('provider','grab','driver_contact','0901234567','reference','TEST-BOOK','recipient_fee',40000);
 BEGIN
  PERFORM public.direct_order_booking_action(shop,r,version,op,'book',booking_payload);RAISE EXCEPTION 'UNCooked_BOOKING_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_COOKING_NOT_COMPLETE' THEN RAISE; END IF; END;
 PERFORM public.direct_delivery_ticket_transition(shop,ticket,version,'preparing');
 SELECT t.version INTO version FROM public.direct_delivery_fulfillment_tickets t WHERE id=ticket;
 BEGIN
  PERFORM public.direct_delivery_ticket_transition(shop,ticket,version,'ready');RAISE EXCEPTION 'UNCooked_READY_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_COOKING_NOT_COMPLETE' THEN RAISE; END IF; END;
 PERFORM public.direct_order_mark_cooked(shop,ticket,version);
 SELECT t.version INTO version FROM public.direct_delivery_fulfillment_tickets t WHERE id=ticket;
 b:=public.direct_order_booking_action(shop,r,version,op,'book',booking_payload);
 IF public.direct_order_booking_action(shop,r,version,op,'book',booking_payload)<>b THEN RAISE EXCEPTION 'BOOKING_REPLAY_CHANGED'; END IF;
 IF (SELECT count(*) FROM public.direct_order_delivery_bookings WHERE request_id=r)<>1
 OR EXISTS(SELECT 1 FROM public.direct_order_dispatches WHERE request_id=r)
 OR EXISTS(SELECT 1 FROM public.direct_order_customer_events WHERE request_id=r AND event_kind='driver_handoff')
 THEN RAISE EXCEPTION 'BOOKING_PREMATURE_HANDOFF'; END IF;
 IF public.direct_order_public_status_v10(sid,secret,r)->'delivery'->'booking'->>'status'<>'booked'
 OR public.direct_order_public_orders_v3(sid,secret,1)->0 ? 'booking_status'
 THEN RAISE EXCEPTION 'BOOKING_API_VERSION_FAILED'; END IF;
 SELECT t.version INTO version FROM public.direct_delivery_fulfillment_tickets t WHERE id=ticket;
 BEGIN
  PERFORM public.direct_order_handoff_booking(shop,r,version,op);RAISE EXCEPTION 'UNPACKED_HANDOFF_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_DELIVERY_TICKET_TRANSITION_INVALID' THEN RAISE; END IF; END;
 PERFORM public.direct_delivery_ticket_transition(shop,ticket,version,'ready');
 SELECT t.version INTO version FROM public.direct_delivery_fulfillment_tickets t WHERE id=ticket;
 PERFORM public.direct_order_handoff_booking(shop,r,version,op);
 PERFORM public.direct_order_handoff_booking(shop,r,version,op);
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_dispatches WHERE request_id=r AND actual_grab_fee IS NULL
 AND customer_delivery_fee=0 AND delivery_payment_mode='customer_direct')
 OR EXISTS(SELECT 1 FROM public.direct_order_driver_cash_movements WHERE request_id=r)
 OR (SELECT final_total FROM public.direct_order_financials WHERE request_id=r)<>108000
 THEN RAISE EXCEPTION 'RECIPIENT_HANDOFF_MONEY_WRONG'; END IF;
 IF (SELECT count(*) FROM public.direct_order_customer_events WHERE request_id=r AND event_kind='driver_handoff')<>1 THEN RAISE EXCEPTION 'HANDOFF_NOTICE_DUPLICATED count=%', (SELECT count(*) FROM public.direct_order_customer_events WHERE request_id=r AND event_kind='driver_handoff'); END IF;
 UPDATE public.users SET role='admin' WHERE auth_id=auth.uid();
 -- The approval fixture has no physical printer; make its queued job eligible
 -- for the real claim contract without changing production routing.
 UPDATE public.print_jobs SET destination_id=gen_random_uuid(),status='pending',attempts=0,next_retry_at=now()
 WHERE order_id=o AND status IN ('pending','failed');
 IF EXISTS(SELECT 1 FROM public.claim_print_jobs(shop,50) WHERE (payload->>'receipt_payload_version')::int>=2) THEN RAISE EXCEPTION 'OLD_AGENT_CLAIMED_NEW_PAYLOAD'; END IF;
 IF NOT EXISTS(SELECT 1 FROM public.claim_print_jobs_v3(shop,50) WHERE payload->>'receipt_payload_version'='2') THEN RAISE EXCEPTION 'NEW_AGENT_CANNOT_CLAIM'; END IF;
 UPDATE public.users SET role='cashier' WHERE auth_id=auth.uid();
 UPDATE public.direct_order_requests SET pii_purged_at=now() WHERE id=r;
 IF EXISTS(SELECT 1 FROM public.direct_order_delivery_bookings WHERE request_id=r AND (driver_contact IS NOT NULL OR tracking_url IS NOT NULL OR mutation_payload<>'{}')) THEN RAISE EXCEPTION 'BOOKING_PII_RETAINED'; END IF;
END; $recipient$;
CREATE TABLE recipient_measurement.money_scopes(size integer,request_id uuid,restaurant_id uuid,expected numeric,evidence_id uuid,operation_id uuid DEFAULT gen_random_uuid());
DO $batch_setup$
DECLARE n integer;f jsonb;r uuid;shop uuid;g integer;o uuid;pid uuid;cid uuid;mid uuid;q uuid;
BEGIN
 FOREACH n IN ARRAY ARRAY[1,10,50] LOOP
  SELECT request_id,restaurant_id INTO r,shop FROM recipient_measurement.legacy_money WHERE size=n;
  UPDATE public.users SET restaurant_id=shop WHERE auth_id=auth.uid();
  SELECT quote_id INTO q FROM public.direct_order_financials WHERE request_id=r;
  PERFORM public.direct_order_staff_quote(shop,r,(SELECT delivery_fee_total FROM public.direct_order_quotes WHERE id=q),NULL);
  -- Older clients omit the optional mode. Preserve their finalized prepaid
  -- quote replay while new requests still default to recipient payment.
  PERFORM public.direct_order_staff_quote_with_payment_mode(shop,r,(SELECT delivery_fee_total FROM public.direct_order_quotes WHERE id=q),NULL);
  FOR g IN 1..n LOOP
   INSERT INTO public.orders(restaurant_id,status) VALUES(shop,'completed') RETURNING id INTO o;
   INSERT INTO public.payments(order_id,restaurant_id,amount,method,is_revenue,amount_portion) VALUES(o,shop,1000,'BANKTRANSFER',true,1000) RETURNING id INTO pid;
   INSERT INTO public.direct_order_payment_charges(request_id,restaurant_id,kind,amount,reason,status,created_by,order_id,payment_id)
    VALUES(r,shop,'delivery',1000,'batch fixture','paid',auth.uid(),o,pid) RETURNING id INTO cid;
   INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,attachment_storage_path)
   VALUES(r,shop,'customer','payment_proof',shop::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg') RETURNING id INTO mid;
   INSERT INTO public.direct_order_payment_receipts(request_id,restaurant_id,charge_id,quote_id,proof_message_id,amount,bank_reference,confirmed_by)
   VALUES(r,shop,cid,q,mid,1000,'batch receipt '||g,auth.uid());
  END LOOP;
  UPDATE public.direct_order_requests SET invoice_details=jsonb_build_object('requested',true,'tax_code','1234567890','legal_name','Buyer',
   'address','123 Test','email','buyer@example.test','phone','0901234567') WHERE id=r;
  mid:=(public.direct_order_commit_chat_attachment(r,shop,'cashier',auth.uid(),shop::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg','refund.jpg','image/jpeg')->>'message_id')::uuid;
  INSERT INTO recipient_measurement.money_scopes(size,request_id,restaurant_id,expected,evidence_id) VALUES(n,r,shop,108000+n*1000,mid);
 END LOOP;
END; $batch_setup$;
CREATE TABLE recipient_measurement.race(request_id uuid,restaurant_id uuid,ticket_id uuid,version integer,booking_id uuid,session_id uuid,secret_hash text);
DO $booking_states$
DECLARE f jsonb;r uuid;shop uuid;ticket uuid;ver integer;op uuid;data jsonb;sid uuid;secret text;v jsonb;
BEGIN
 f:=photo_test.create_request(true,'customer_direct');r:=(f->>'request_id')::uuid;shop:=(f->>'store_id')::uuid;
 UPDATE public.users SET restaurant_id=shop WHERE auth_id=auth.uid();PERFORM photo_test.approve(f);
 SELECT t.id,t.version INTO ticket,ver FROM public.direct_delivery_fulfillment_tickets t WHERE t.request_id=r;
 PERFORM public.direct_delivery_ticket_transition(shop,ticket,ver,'preparing');
 SELECT t.version INTO ver FROM public.direct_delivery_fulfillment_tickets t WHERE t.id=ticket;
 PERFORM public.direct_order_mark_cooked(shop,ticket,ver);
 SELECT t.version INTO ver FROM public.direct_delivery_fulfillment_tickets t WHERE t.id=ticket;
 data:='{"provider":"grab","driver_contact":"0901234567"}'::jsonb;op:=gen_random_uuid();
 PERFORM public.direct_order_booking_action(shop,r,ver,op,'book',data);
 BEGIN
  PERFORM public.direct_order_booking_action(shop,r,ver,gen_random_uuid(),'cancel','{"reason":"stale cancel"}');RAISE EXCEPTION 'STALE_CANCEL_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_BOOKING_CHANGED' THEN RAISE; END IF; END;
 SELECT t.version INTO ver FROM public.direct_delivery_fulfillment_tickets t WHERE t.id=ticket;
 PERFORM public.direct_order_booking_action(shop,r,ver,gen_random_uuid(),'fail','{"reason":"recipient payment unavailable"}');
 IF public.direct_order_booking_snapshot(r)->>'status'<>'failed' OR EXISTS(SELECT 1 FROM public.direct_order_dispatches WHERE request_id=r)
 THEN RAISE EXCEPTION 'FAILED_BOOKING_BECAME_HANDOFF'; END IF;
 SELECT t.version INTO ver FROM public.direct_delivery_fulfillment_tickets t WHERE t.id=ticket;
 PERFORM public.direct_delivery_ticket_transition(shop,ticket,ver,'ready');
 SELECT t.version INTO ver FROM public.direct_delivery_fulfillment_tickets t WHERE t.id=ticket;
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=r;
 SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
 INSERT INTO recipient_measurement.race VALUES(r,shop,ticket,ver,gen_random_uuid(),sid,secret);
 -- Nothing can collect courier fees through old support routes.
 BEGIN
  PERFORM public.direct_order_staff_support_action(shop,r,1,'reconcile_delivery_fee','{}');RAISE EXCEPTION 'LEGACY_RECONCILIATION_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_RECIPIENT_PAYMENT_REQUIRED' THEN RAISE; END IF; END;
 UPDATE public.users SET role='admin' WHERE auth_id=auth.uid();
 v:=public.direct_order_analytics_v4(shop,(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date,(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date);
 IF (v->'summary'->>'booking_failures')::int<1 OR (v->'summary'->>'awaiting_booking')::int<1 THEN RAISE EXCEPTION 'BOOKING_METRICS_MISSING'; END IF;
 UPDATE public.users SET role='cashier' WHERE auth_id=auth.uid();
END; $booking_states$;

DO $native_pickup$
DECLARE f jsonb;shop uuid;r uuid;t uuid;ver integer;
BEGIN
 f:=photo_test.create_request(true,'not_applicable','pickup');
 shop:=(f->>'store_id')::uuid;r:=(f->>'request_id')::uuid;
 UPDATE public.users SET restaurant_id=shop WHERE auth_id=auth.uid();
 PERFORM public.direct_order_staff_quote_with_payment_mode(shop,r,0,NULL);
 PERFORM photo_test.approve(f);
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=r AND delivery_payment_mode='not_applicable' AND delivery_fee_total=0)
 THEN RAISE EXCEPTION 'NATIVE_PICKUP_FEE_POLICY_DRIFT'; END IF;
 SELECT id,version INTO t,ver FROM public.direct_delivery_fulfillment_tickets WHERE request_id=r;
 PERFORM public.direct_delivery_ticket_transition(shop,t,ver,'preparing');
 SELECT version INTO ver FROM public.direct_delivery_fulfillment_tickets WHERE id=t;
 PERFORM public.direct_order_mark_cooked(shop,t,ver);
 SELECT version INTO ver FROM public.direct_delivery_fulfillment_tickets WHERE id=t;
 PERFORM public.direct_delivery_ticket_transition(shop,t,ver,'ready');
 SELECT version INTO ver FROM public.direct_delivery_fulfillment_tickets WHERE id=t;
 BEGIN
  PERFORM public.direct_order_booking_action(shop,r,ver,gen_random_uuid(),'book','{"provider":"grab"}');
  RAISE EXCEPTION 'NATIVE_PICKUP_BOOKING_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_BOOKING_CHANGED' THEN RAISE; END IF; END;
 PERFORM public.direct_order_cashier_complete_pickup(shop,r,ver);
 PERFORM public.direct_order_cashier_complete_pickup(shop,r,ver);
 IF (SELECT status FROM public.direct_delivery_fulfillment_tickets WHERE id=t)<>'completed'
 OR EXISTS(SELECT 1 FROM public.direct_order_dispatches WHERE request_id=r)
 THEN RAISE EXCEPTION 'NATIVE_PICKUP_COMPLETION_DRIFT'; END IF;
 RAISE NOTICE 'RECIPIENT_NATIVE_PICKUP_QUOTE_COOK_PACK_COMPLETE=PASS';
END; $native_pickup$;
