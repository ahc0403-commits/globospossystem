DO $test$
DECLARE f jsonb; s uuid; r uuid; q uuid; proof uuid; charge uuid; detail jsonb; original_stock numeric; result jsonb; original_order uuid; fee_order uuid; version integer;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid'); s:=(f->>'store_id')::uuid;r:=(f->>'request_id')::uuid;q:=(f->>'quote_id')::uuid;proof:=(f->>'proof_id')::uuid;
 SELECT current_stock INTO original_stock FROM public.inventory_items WHERE restaurant_id=s LIMIT 1;
 UPDATE public.direct_order_requests SET delivery_fee_deferred=true,delivery_fee_finalized=false WHERE id=r;
 PERFORM public.direct_order_staff_support_action(s,r,1,'invoice',jsonb_build_object('requested',true,'legal_name','Support fixture','tax_code','TEST','address','Test address','email','test@example.test','phone','0900000000'));
 result:=public.direct_order_record_receipt(s,r,q,proof,100000,'bank-fixture-food');
 IF (result->>'food_due')::numeric<>8000 THEN RAISE EXCEPTION 'PARTIAL_RECEIPT_BALANCE'; END IF;
 PERFORM photo_test.assert_empty_graph(r);
 PERFORM public.direct_order_record_receipt(s,r,q,proof,100000,'bank-fixture-food');
 IF (SELECT count(*) FROM public.direct_order_payment_receipts WHERE request_id=r)<>1 THEN RAISE EXCEPTION 'DUPLICATE_RECEIPT'; END IF;
 BEGIN PERFORM public.direct_order_record_receipt(s,r,q,proof,99000,'bank-fixture-food'); RAISE EXCEPTION 'CHANGED_RECEIPT_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED' THEN RAISE; END IF; END;
 SELECT support_version INTO version FROM public.direct_order_requests WHERE id=r;
 PERFORM public.direct_order_staff_support_action(s,r,version,'charge',jsonb_build_object('kind','food_balance','amount',8000,'reason','Food shortfall'));
 SELECT id INTO charge FROM public.direct_order_payment_charges WHERE request_id=r AND kind='food_balance';
 SELECT public.direct_order_commit_attachment(r,s,'customer',NULL,s::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg','topup.jpg',charge) INTO detail;
 proof:=(detail->>'message_id')::uuid;
 PERFORM public.direct_order_record_receipt(s,r,q,proof,8000,'bank-fixture-topup');
 PERFORM photo_test.assert_single_graph(r);
 SELECT order_id INTO original_order FROM public.direct_order_financials WHERE request_id=r;
 IF NOT EXISTS(SELECT 1 FROM support_invoice_fixture WHERE order_id=original_order AND payload->>'tax_code'='TEST') THEN RAISE EXCEPTION 'INVOICE_NOT_CONNECTED'; END IF;
 BEGIN PERFORM public.direct_order_assert_settled(r); RAISE EXCEPTION 'UNCONFIRMED_DELIVERY_SETTLED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_PAYMENT_PENDING' THEN RAISE; END IF; END;
 SELECT support_version INTO version FROM public.direct_order_requests WHERE id=r;
 PERFORM public.direct_order_staff_support_action(s,r,version,'charge',jsonb_build_object('kind','delivery','amount',30000,'reason','Actual delivery cost'));
 SELECT id INTO charge FROM public.direct_order_payment_charges WHERE request_id=r AND kind='delivery';
 BEGIN PERFORM public.direct_order_commit_attachment(r,s,'customer',NULL,s::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg','delivery.jpg',charge); RAISE EXCEPTION 'CONSENT_BYPASSED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_CHARGE_CHANGED' THEN RAISE; END IF; END;
 SELECT session_id INTO s FROM public.direct_order_requests WHERE id=r;
 SELECT public.direct_order_public_charge_consent(s,secret_hash,r,charge,true) INTO result FROM public.direct_order_sessions WHERE id=s;
 s:=(f->>'store_id')::uuid;
 SELECT public.direct_order_commit_attachment(r,s,'customer',NULL,s::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg','delivery.jpg',charge) INTO detail;
 proof:=(detail->>'message_id')::uuid;
 PERFORM public.direct_order_record_receipt(s,r,q,proof,30000,'bank-fixture-delivery');
 PERFORM public.direct_order_assert_settled(r);
 SELECT order_id INTO fee_order FROM public.direct_order_payment_charges WHERE id=charge;
 IF fee_order IS NULL OR fee_order=original_order OR (SELECT count(*) FROM public.payments WHERE order_id=fee_order)<>1 THEN RAISE EXCEPTION 'SUPPLEMENTAL_PAYMENT_MISSING'; END IF;
 IF (SELECT current_stock FROM public.inventory_items WHERE restaurant_id=s LIMIT 1)<>original_stock-10 THEN RAISE EXCEPTION 'SUPPLEMENTAL_PAYMENT_DEDUCTED_FOOD'; END IF;
 IF (SELECT count(*) FROM public.direct_delivery_fulfillment_tickets WHERE request_id=r)<>1 THEN RAISE EXCEPTION 'DUPLICATE_KITCHEN_TICKET'; END IF;
 IF (SELECT count(*) FROM public.direct_order_payment_receipts WHERE request_id=r)<>3 THEN RAISE EXCEPTION 'PROOF_HISTORY_LOST'; END IF;
 SELECT to_jsonb(public.enqueue_receipt_print_job(original_order,true)) INTO detail;
 IF NOT EXISTS(SELECT 1 FROM public.print_jobs WHERE order_id=original_order AND payload->>'direct_order_settlement'='true' AND (payload->>'total_amount')::numeric=138000) THEN RAISE EXCEPTION 'FINAL_RECEIPT_NOT_CONSOLIDATED'; END IF;
 SELECT support_version INTO version FROM public.direct_order_requests WHERE id=r;
 PERFORM public.direct_order_staff_support_action(s,r,version,'cancel_order','{}');
 PERFORM public.direct_order_staff_message(s,r,'Refund support remains open');
 SELECT session_id INTO s FROM public.direct_order_requests WHERE id=r;
 PERFORM public.direct_order_public_message(s,(SELECT secret_hash FROM public.direct_order_sessions WHERE id=s),r,'Please refund');
 s:=(f->>'store_id')::uuid;
 SELECT support_version INTO version FROM public.direct_order_requests WHERE id=r;
 PERFORM public.direct_order_staff_support_action(s,r,version,'refund_details',jsonb_build_object('bank','Test bank','account','Test account','holder','Test holder'));
 SELECT support_version INTO version FROM public.direct_order_requests WHERE id=r;
 BEGIN PERFORM public.direct_order_staff_support_action(s,r,version,'close_chat','{}'); RAISE EXCEPTION 'REFUND_CHAT_CLOSED_EARLY';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_REFUND_PENDING' THEN RAISE; END IF; END;
 detail:=jsonb_build_object('amount',138000,'reference','refund-fixture','operation_id',gen_random_uuid());
 PERFORM public.direct_order_staff_support_action(s,r,version,'refund_complete',detail);
 PERFORM public.direct_order_staff_support_action(s,r,version,'refund_complete',detail);
 IF (SELECT count(*) FROM public.direct_order_refund_records WHERE request_id=r)<>1 OR (SELECT sum(amount) FROM public.payment_adjustments WHERE payment_id IN (SELECT id FROM public.payments WHERE order_id IN (original_order,fee_order)))<>138000 THEN RAISE EXCEPTION 'REFUND_LEDGER_MISMATCH'; END IF;
 SELECT support_version INTO version FROM public.direct_order_requests WHERE id=r;
 PERFORM public.direct_order_staff_support_action(s,r,version,'close_chat','{}');
 BEGIN PERFORM public.direct_order_staff_message(s,r,'Closed'); RAISE EXCEPTION 'CLOSED_CHAT_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_REQUEST_NOT_CHATABLE' THEN RAISE; END IF; END;
 IF public.direct_order_support_context(r,false)::text LIKE '%Test account%' OR public.direct_order_support_context(r,false)::text LIKE '%tax_code%' THEN RAISE EXCEPTION 'PRIVATE_SUPPORT_DATA_LEAK'; END IF;
END;
$test$;
SELECT 'DIRECT_ORDER_SUPPORT_PAYMENTS=PASS';
-- Original shipping was prepaid, then actual shipping increased. Multiple
-- additional charges remain on one request without cooking food again.
DO $additional$
DECLARE f jsonb; s uuid; r uuid; q uuid; m uuid; c uuid; v integer; x jsonb; original uuid; first_print uuid; stock numeric; loop_number integer; session uuid;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid');s:=(f->>'store_id')::uuid;r:=(f->>'request_id')::uuid;q:=(f->>'quote_id')::uuid;m:=(f->>'proof_id')::uuid;
 UPDATE public.direct_order_quotes SET delivery_fee_pretax=27777.78,delivery_fee_vat=2222.22,delivery_fee_total=30000,final_total=138000 WHERE id=q;
 SELECT current_stock INTO stock FROM public.inventory_items WHERE restaurant_id=s LIMIT 1;
 PERFORM public.direct_order_record_receipt(s,r,q,m,138000,'prepaid-original');
 SELECT order_id INTO original FROM public.direct_order_financials WHERE request_id=r;
 SELECT id INTO first_print FROM public.print_jobs WHERE order_id=original LIMIT 1;
 FOR loop_number IN 1..2 LOOP
  SELECT support_version INTO v FROM public.direct_order_requests WHERE id=r;
  PERFORM public.direct_order_staff_support_action(s,r,v,'charge',jsonb_build_object('kind','delivery','amount',15000,'reason','Actual delivery fee exceeds collected amount'));
  SELECT id INTO c FROM public.direct_order_payment_charges WHERE request_id=r AND status='awaiting_consent';
  SELECT session_id INTO session FROM public.direct_order_requests WHERE id=r;
  PERFORM public.direct_order_public_charge_consent(session,(SELECT secret_hash FROM public.direct_order_sessions WHERE id=session),r,c,true);
  x:=public.direct_order_commit_attachment(r,s,'customer',NULL,s::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg','additional-fee.jpg',c);m:=(x->>'message_id')::uuid;
  BEGIN PERFORM public.direct_order_record_receipt(s,r,q,m,16000,'overpaid');RAISE EXCEPTION 'OVERPAYMENT_ACCEPTED';
  EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_AMOUNT_EXCEEDS_DUE' THEN RAISE; END IF;END;
  PERFORM public.direct_order_record_receipt(s,r,q,m,15000,'delivery-difference-'||loop_number);
  PERFORM public.direct_order_record_receipt(s,r,q,m,15000,'delivery-difference-'||loop_number);
 END LOOP;
 PERFORM public.direct_order_assert_settled(r);
 IF (SELECT count(*) FROM public.direct_delivery_fulfillment_tickets WHERE request_id=r)<>1 OR (SELECT current_stock FROM public.inventory_items WHERE restaurant_id=s LIMIT 1)<>stock-10 THEN RAISE EXCEPTION 'ADDITIONAL_FEE_DUPLICATED_FOOD';END IF;
 IF (public.direct_order_fulfillment_context(r)->>'paid_total')::numeric<>168000 THEN RAISE EXCEPTION 'CUSTOMER_HEADER_LOST_ADDITIONAL_RECEIPTS';END IF;
 PERFORM public.enqueue_receipt_print_job(original,true);
 IF NOT EXISTS(SELECT 1 FROM public.print_jobs WHERE order_id=original AND (payload->>'total_amount')::numeric=168000) THEN RAISE EXCEPTION 'ADDITIONAL_FINAL_RECEIPT_TOTAL';END IF;
 IF (SELECT (payload->>'total_amount')::numeric FROM public.print_jobs WHERE id=first_print)<>138000 THEN RAISE EXCEPTION 'ISSUED_PRINT_SNAPSHOT_CHANGED';END IF;
 INSERT INTO public.digital_receipts(restaurant_id,order_id,snapshot) VALUES(s,original,jsonb_build_object('total_amount',138000,'items','[]'::jsonb,'payments','[]'::jsonb));
 IF (SELECT (snapshot->>'total_amount')::numeric FROM public.digital_receipts WHERE order_id=original)<>168000 THEN RAISE EXCEPTION 'DIGITAL_SETTLEMENT_TOTAL';END IF;
 UPDATE public.direct_delivery_fulfillment_tickets SET status='ready',version=version+1 WHERE request_id=r;
 SELECT fulfillment_version INTO v FROM public.direct_order_requests WHERE id=r;
 SELECT version INTO v FROM public.direct_delivery_fulfillment_tickets WHERE request_id=r;
 PERFORM public.direct_order_set_dispatch_v3(s,r,v,'grab','https://fixture.test/track',60000,NULL,'Fixture driver');
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_dispatches WHERE request_id=r AND customer_delivery_fee=60000 AND fee_variance=0) THEN RAISE EXCEPTION 'DELIVERY_CASH_PAYOUT_RECONCILIATION';END IF;
END;
$additional$;
-- Unposted advances stay refundable and visible after cancellation and day roll.
DO $advance$
DECLARE f jsonb; s uuid;r uuid;q uuid;m uuid;v integer;x jsonb; op uuid:=gen_random_uuid();
BEGIN
 f:=photo_test.create_request();s:=(f->>'store_id')::uuid;r:=(f->>'request_id')::uuid;q:=(f->>'quote_id')::uuid;m:=(f->>'proof_id')::uuid;
 PERFORM public.direct_order_record_receipt(s,r,q,m,30000,'unposted-fixture');
 UPDATE public.direct_order_requests SET state='cancelled',created_at=now()-interval '100 days' WHERE id=r;
 SELECT support_version INTO v FROM public.direct_order_requests WHERE id=r;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.direct_order_staff_list_v3(s,NULL,200)) p WHERE p->>'id'=r::text) THEN RAISE EXCEPTION 'OLD_REFUND_CONVERSATION_HIDDEN';END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(public.direct_order_cleanup_candidates(500)) p WHERE p->>'request_id'=r::text) THEN RAISE EXCEPTION 'OPEN_REFUND_EVIDENCE_PURGED';END IF;
 BEGIN PERFORM public.direct_order_staff_support_action(s,r,v,'close_chat','{}');RAISE EXCEPTION 'UNPOSTED_REFUND_CHAT_CLOSED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_REFUND_PENDING' THEN RAISE;END IF;END;
 PERFORM public.direct_order_staff_support_action(s,r,v,'refund_complete',jsonb_build_object('operation_id',op,'amount',30000,'reference','advance-refund'));
 IF (SELECT sum(unposted_amount) FROM public.direct_order_refund_records WHERE request_id=r)<>30000 OR (public.direct_order_support_context(r,true)->>'refund_due')::numeric<>0 THEN RAISE EXCEPTION 'UNPOSTED_ADVANCE_NOT_REFUNDED';END IF;
 BEGIN PERFORM public.direct_order_staff_support_action(s,r,v,'refund_complete',jsonb_build_object('operation_id',op,'amount',31000,'reference','advance-refund'));RAISE EXCEPTION 'CHANGED_REFUND_REPLAY_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_SUPPORT_CHANGED' THEN RAISE;END IF;END;
 SELECT support_version INTO v FROM public.direct_order_requests WHERE id=r;
 PERFORM public.direct_order_staff_support_action(s,r,v,'close_chat','{}');
 PERFORM public.direct_order_cleanup_expired_pii(ARRAY[r]);
 IF EXISTS(SELECT 1 FROM public.direct_order_messages WHERE request_id=r AND attachment_storage_path IS NOT NULL) OR (SELECT count(*) FROM public.direct_order_payment_receipts WHERE request_id=r)<>1 THEN RAISE EXCEPTION 'RETENTION_DESTROYED_RECEIPT_OR_RETAINED_EVIDENCE';END IF;
 PERFORM photo_test.assert_empty_graph(r);
END;
$advance$;
SELECT 'DIRECT_ORDER_ADDITIONAL_SHIPPING_AND_ADVANCE_REFUND=PASS';

-- Consented pickup must void open delivery charges and return both posted
-- supplemental shipping and partial advances before handing food to the diner.
DO $pickup$
DECLARE f jsonb;s uuid;r uuid;q uuid;m uuid;c uuid;v integer;x jsonb;sid uuid;offer uuid;op uuid:=gen_random_uuid();food_payment uuid;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid');s:=(f->>'store_id')::uuid;r:=(f->>'request_id')::uuid;q:=(f->>'quote_id')::uuid;m:=(f->>'proof_id')::uuid;
 PERFORM public.direct_order_record_receipt(s,r,q,m,108000,'pickup-food');
 SELECT payment_id INTO food_payment FROM public.direct_order_financials WHERE request_id=r;
 FOR v IN 1..2 LOOP
  SELECT support_version INTO v FROM public.direct_order_requests WHERE id=r;
  PERFORM public.direct_order_staff_support_action(s,r,v,'charge',jsonb_build_object('kind','delivery','amount',15000,'reason','Pickup test shipping'));
  SELECT id INTO c FROM public.direct_order_payment_charges WHERE request_id=r AND status='awaiting_consent';
  SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=r;
  PERFORM public.direct_order_public_charge_consent(sid,(SELECT secret_hash FROM public.direct_order_sessions WHERE id=sid),r,c,true);
  x:=public.direct_order_commit_attachment(r,s,'customer',NULL,s::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg','pickup-fee.jpg',c);m:=(x->>'message_id')::uuid;
  PERFORM public.direct_order_record_receipt(s,r,q,m,CASE WHEN EXISTS(SELECT 1 FROM public.direct_order_payment_charges WHERE request_id=r AND status='paid') THEN 5000 ELSE 15000 END,'pickup-fee-'||c);
 END LOOP;
 SELECT fulfillment_version INTO v FROM public.direct_order_requests WHERE id=r;
 PERFORM public.direct_order_staff_offer_pickup(s,r,v,'Customer chooses pickup');
 SELECT id INTO offer FROM public.direct_order_pickup_offers WHERE request_id=r;
 PERFORM public.direct_order_public_decide_pickup(sid,(SELECT secret_hash FROM public.direct_order_sessions WHERE id=sid),r,offer,true,true);
 IF EXISTS(SELECT 1 FROM public.direct_order_payment_charges WHERE request_id=r AND status NOT IN ('paid','void'))
  OR (public.direct_order_support_context(r,true)->>'pickup_delivery_refund_due')::numeric<>20000 THEN RAISE EXCEPTION 'PICKUP_SUPPLEMENTAL_REFUND_BALANCE';END IF;
 UPDATE public.direct_delivery_fulfillment_tickets SET status='ready',version=version+1 WHERE request_id=r;
 SELECT version INTO v FROM public.direct_delivery_fulfillment_tickets WHERE request_id=r;
 BEGIN PERFORM public.direct_order_cashier_complete_pickup(s,r,v);RAISE EXCEPTION 'PICKUP_COMPLETED_BEFORE_SUPPLEMENTAL_REFUND';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_PAYMENT_PENDING' THEN RAISE;END IF;END;
 SELECT support_version INTO v FROM public.direct_order_requests WHERE id=r;
 x:=jsonb_build_object('operation_id',op,'amount',20000,'reference','pickup-fees-refunded');
 PERFORM public.direct_order_staff_support_action(s,r,v,'refund_delivery_complete',x);
 PERFORM public.direct_order_staff_support_action(s,r,v,'refund_delivery_complete',x);
 IF public.direct_order_supplemental_delivery_refund_due(r)<>0
  OR EXISTS(SELECT 1 FROM public.payment_adjustments WHERE payment_id=food_payment)
  OR (SELECT sum(unposted_amount) FROM public.direct_order_refund_records WHERE request_id=r)<>5000 THEN RAISE EXCEPTION 'PICKUP_REFUND_TOUCHED_FOOD_OR_LOST_ADVANCE';END IF;
 x:=public.direct_order_fulfillment_context(r);
 IF (x->>'paid_total')::numeric-(x->>'refunded_total')::numeric<>108000 THEN RAISE EXCEPTION 'CUSTOMER_HEADER_PICKUP_REFUND_NET';END IF;
 SELECT version INTO v FROM public.direct_delivery_fulfillment_tickets WHERE request_id=r;
 PERFORM public.direct_order_cashier_complete_pickup(s,r,v);
 IF NOT EXISTS(SELECT 1 FROM public.print_jobs p JOIN public.direct_order_financials f ON f.order_id=p.order_id
  WHERE f.request_id=r AND p.payload->>'direct_order_settlement'='true' AND (p.payload->>'total_amount')::numeric=123000
   AND (p.payload->>'refunded_total')::numeric=15000 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(p.payload->'items') i WHERE i->>'label'='Phí giao hàng'))
  THEN RAISE EXCEPTION 'FINAL_PICKUP_RECEIPT_REFUND_OR_QUEUE_MISSING';END IF;
 -- Deferred delivery with no received fee can complete pickup normally.
 f:=photo_test.create_request(true,'store_prepaid');s:=(f->>'store_id')::uuid;r:=(f->>'request_id')::uuid;q:=(f->>'quote_id')::uuid;m:=(f->>'proof_id')::uuid;
 UPDATE public.direct_order_requests SET delivery_fee_deferred=true,delivery_fee_finalized=false WHERE id=r;
 PERFORM public.direct_order_record_receipt(s,r,q,m,108000,'pickup-deferred-food');
 SELECT fulfillment_version INTO v FROM public.direct_order_requests WHERE id=r;
 PERFORM public.direct_order_staff_offer_pickup(s,r,v,'Pickup replaces deferred delivery');
 SELECT id INTO offer FROM public.direct_order_pickup_offers WHERE request_id=r;
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=r;
 PERFORM public.direct_order_public_decide_pickup(sid,(SELECT secret_hash FROM public.direct_order_sessions WHERE id=sid),r,offer,true,true);
 PERFORM public.direct_order_assert_settled(r);
END;
$pickup$;
SELECT 'DIRECT_ORDER_PICKUP_SUPPLEMENTAL_REFUND=PASS';

DO $payment_notice$
DECLARE f jsonb;r uuid;s uuid;sid uuid;q uuid;old_q uuid;rows jsonb;device uuid:=gen_random_uuid();
BEGIN
 f:=photo_test.create_request(true);r:=(f->>'request_id')::uuid;s:=(f->>'store_id')::uuid;old_q:=(f->>'quote_id')::uuid;
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=r;
 PERFORM public.direct_order_public_push_subscription(sid,(SELECT secret_hash FROM public.direct_order_sessions WHERE id=sid),device,repeat('payment_fixture_token',3),'ko',true);
 INSERT INTO public.direct_order_push_deliveries(event_id,session_id,device_id)
 SELECT id,sid,device FROM public.direct_order_customer_events WHERE request_id=r AND subject_id=old_q;
 UPDATE public.direct_order_quotes SET status='superseded' WHERE id=old_q;
 UPDATE public.direct_order_requests SET state='awaiting_quote' WHERE id=r;
 -- A real quote command inserts its payment notice after the device is registered.
 PERFORM public.direct_order_staff_quote_with_payment_mode(s,r,0,'Payment notice fixture','customer_direct');
 SELECT id INTO q FROM public.direct_order_quotes WHERE request_id=r AND status='active';
 PERFORM public.direct_order_notify_payment(r,q);
 IF (SELECT count(*) FROM public.direct_order_customer_events WHERE request_id=r AND event_kind='payment_request' AND subject_id=q)<>1
  OR (SELECT count(*) FROM public.direct_order_push_deliveries d JOIN public.direct_order_customer_events e ON e.id=d.event_id WHERE e.request_id=r AND e.subject_id=q)<>1 THEN RAISE EXCEPTION 'PAYMENT_NOTICE_DUPLICATED_OR_MISSING';END IF;
 rows:=public.claim_direct_order_push_deliveries(100);
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(rows) x WHERE x->>'request_id'=r::text AND x->>'event_kind'='payment_request') THEN RAISE EXCEPTION 'ACTIVE_PAYMENT_NOTICE_NOT_CLAIMED';END IF;
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_push_deliveries d JOIN public.direct_order_customer_events e ON e.id=d.event_id WHERE e.request_id=r AND e.subject_id=old_q AND d.status='skipped') THEN RAISE EXCEPTION 'SUPERSEDED_PAYMENT_NOTICE_NOT_SKIPPED';END IF;
END;
$payment_notice$;
SELECT 'DIRECT_ORDER_PAYMENT_NOTICE=PASS';

-- Strict preceding clients keep their response keys during staged deployment.
DO $compatibility$
DECLARE f jsonb; sid uuid; rid uuid; secret text; payload jsonb;
BEGIN
 f:=photo_test.create_request();rid:=(f->>'request_id')::uuid;
 SELECT r.session_id,s.secret_hash INTO sid,secret FROM public.direct_order_requests r JOIN public.direct_order_sessions s ON s.id=r.session_id WHERE r.id=rid;
 payload:=public.direct_order_public_status_v4(sid,secret,rid);
 ASSERT NOT payload ? 'support','PRECEDING_CUSTOMER_RESPONSE_CHANGED';
 ASSERT public.direct_order_public_status_v5(sid,secret,rid) ? 'support','SUPPORT_V5_MISSING';
 ASSERT public.direct_order_public_status_v5(sid,secret,rid)->'customer'=payload->'customer','CUSTOMER_CONTEXT_LOST';
 ASSERT NOT public.direct_order_staff_detail_v3((f->>'store_id')::uuid,rid) ? 'support','PRECEDING_STAFF_RESPONSE_CHANGED';
 ASSERT public.direct_order_staff_detail_v4((f->>'store_id')::uuid,rid) ? 'support','STAFF_SUPPORT_V4_MISSING';
END;
$compatibility$;
SELECT 'DIRECT_ORDER_SUPPORT_RESPONSE_COMPATIBILITY=PASS';
