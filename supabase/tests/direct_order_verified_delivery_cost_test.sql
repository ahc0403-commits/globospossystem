DO $test$
DECLARE f jsonb; r uuid; store uuid; quote uuid; proof uuid; evidence uuid; op uuid; value jsonb; secret text; session uuid;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid'); r:=(f->>'request_id')::uuid;store:=(f->>'store_id')::uuid;quote:=(f->>'quote_id')::uuid;proof:=(f->>'proof_id')::uuid;
 PERFORM public.direct_order_approve_photo_payment(store,r,108000,quote,proof);
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path) VALUES(r,store,'cashier','attachment','Grab booking evidence',store::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg') RETURNING id INTO evidence;
 op:=gen_random_uuid();
 value:=public.direct_order_staff_support_action(store,r,1,'reconcile_delivery_fee',jsonb_build_object('operation_id',op,'amount',20000,'provider','grab','reference','grab-booking-001','evidence_message_id',evidence));
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_payment_charges WHERE request_id=r AND kind='delivery' AND amount=20000 AND status='pending') THEN RAISE EXCEPTION 'VERIFIED_COST_NO_PENDING_DELTA'; END IF;
 PERFORM public.direct_order_staff_support_action(store,r,1,'reconcile_delivery_fee',jsonb_build_object('operation_id',op,'amount',20000,'provider','grab','reference','grab-booking-001','evidence_message_id',evidence));
 IF (SELECT count(*) FROM public.direct_order_delivery_cost_changes WHERE request_id=r)<>1 THEN RAISE EXCEPTION 'DELIVERY_COST_RETRY_DUPLICATED'; END IF;
 BEGIN PERFORM public.direct_order_staff_support_action(store,r,2,'charge','{"kind":"delivery","amount":1,"reason":"free input"}');RAISE EXCEPTION 'ARBITRARY_DELIVERY_CHARGE_ACCEPTED'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_DELIVERY_EVIDENCE_REQUIRED' THEN RAISE; END IF; END;
 BEGIN PERFORM public.direct_order_staff_support_action(store,r,2,'reconcile_delivery_fee',jsonb_build_object('operation_id',gen_random_uuid(),'amount',30000,'provider','grab','reference','missing','evidence_message_id',proof));RAISE EXCEPTION 'PAYMENT_PROOF_ACCEPTED_AS_COST'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_DELIVERY_EVIDENCE_REQUIRED' THEN RAISE; END IF; END;
 BEGIN PERFORM public.direct_order_assert_settled(r);RAISE EXCEPTION 'UNPAID_DELIVERY_DISPATCH_ALLOWED'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_PAYMENT_PENDING' THEN RAISE; END IF; END;
 -- The same proof and frozen quote collect only the calculated supplement.
 SELECT session_id INTO session FROM public.direct_order_requests WHERE id=r;SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=session;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path,metadata)
 SELECT r,store,'customer','payment_proof','Delivery payment',store::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg',jsonb_build_object('quote_id',quote,'charge_id',id) FROM public.direct_order_payment_charges WHERE request_id=r AND status='pending' RETURNING id INTO proof;
 PERFORM public.direct_order_record_receipt(store,r,quote,proof,20000,'BANK-DELIVERY-001');
 value:=public.direct_order_staff_support_action(store,r,3,'reconcile_delivery_fee',jsonb_build_object('operation_id',gen_random_uuid(),'amount',15000,'provider','grab','reference','grab-final-001','evidence_message_id',evidence));
 IF (value->>'delivery_adjustment_refund_due')::numeric<>5000 THEN RAISE EXCEPTION 'DELIVERY_REFUND_DELTA_WRONG: %',value; END IF;
 BEGIN PERFORM public.direct_order_assert_settled(r);RAISE EXCEPTION 'UNREFUNDED_DELIVERY_ALLOWED'; EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_PAYMENT_PENDING' THEN RAISE; END IF; END;
 value:=public.direct_order_staff_support_action(store,r,4,'refund_delivery_adjustment',jsonb_build_object('operation_id',gen_random_uuid(),'amount',5000,'reference','BANK-REFUND-001'));
 IF (value->>'delivery_adjustment_refund_due')::numeric<>0 THEN RAISE EXCEPTION 'DELIVERY_REFUND_NOT_CLEARED'; END IF;
 PERFORM public.direct_order_assert_settled(r);
 IF (SELECT final_total FROM public.direct_order_quotes WHERE id=quote)<>108000 THEN RAISE EXCEPTION 'DELIVERY_COST_CHANGED_ORIGINAL_QUOTE'; END IF;
 UPDATE public.direct_delivery_fulfillment_tickets SET status='ready' WHERE request_id=r;
 PERFORM public.direct_order_set_dispatch_v3(store,r,(SELECT version FROM public.direct_delivery_fulfillment_tickets WHERE request_id=r),'grab',NULL,15000,NULL,'0901234567');
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_dispatches WHERE request_id=r AND customer_delivery_fee=15000 AND actual_grab_fee=15000 AND fee_variance=0) THEN RAISE EXCEPTION 'NET_DELIVERY_COLLECTION_WRONG'; END IF;
END; $test$;
SELECT 'DIRECT_ORDER_VERIFIED_DELIVERY_COST=PASS';

DO $customer_direct$
DECLARE f jsonb; r uuid; store uuid; evidence uuid; session uuid; secret text; v jsonb;
BEGIN
 f:=photo_test.create_request(true,'customer_direct'); r:=(f->>'request_id')::uuid;store:=(f->>'store_id')::uuid;
 PERFORM public.direct_order_approve_photo_payment(store,r,108000,(f->>'quote_id')::uuid,(f->>'proof_id')::uuid);
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path) VALUES(r,store,'cashier','attachment','Driver-paid booking evidence',store::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg') RETURNING id INTO evidence;
 v:=public.direct_order_staff_support_action(store,r,1,'reconcile_delivery_fee',jsonb_build_object('operation_id',gen_random_uuid(),'amount',12000,'provider','grab','reference','direct-driver-cost','evidence_message_id',evidence));
 IF EXISTS(SELECT 1 FROM public.direct_order_payment_charges WHERE request_id=r AND kind='delivery') OR (v->>'delivery_adjustment_refund_due')::numeric<>0 THEN RAISE EXCEPTION 'DRIVER_PAID_CUSTOMER_DOUBLE_CHARGED'; END IF;
 SELECT session_id INTO session FROM public.direct_order_requests WHERE id=r;SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=session;
 PERFORM public.direct_order_issue_access(session,secret,r,repeat('e',64));
 UPDATE public.direct_delivery_fulfillment_tickets SET status='ready' WHERE request_id=r;
 PERFORM public.direct_order_set_dispatch_v3(store,r,(SELECT version FROM public.direct_delivery_fulfillment_tickets WHERE request_id=r),'grab',NULL,NULL,NULL,'0901234567');
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_dispatches WHERE request_id=r AND actual_grab_fee IS NULL AND cash_paid_at IS NULL AND delivery_payment_mode='customer_direct') THEN RAISE EXCEPTION 'DRIVER_PAID_STORE_PAYOUT_CREATED'; END IF;
 UPDATE public.direct_delivery_fulfillment_tickets SET status='completed' WHERE request_id=r;
 BEGIN PERFORM public.direct_order_resolve_access(r,repeat('e',64));RAISE EXCEPTION 'DELIVERED_ORDER_LINK_OPEN';EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_ORDER_CLOSED' THEN RAISE; END IF;END;
END; $customer_direct$;
SELECT 'DIRECT_ORDER_DRIVER_PAID_COST_AND_COMPLETION=PASS';

DO $partial_advance$
DECLARE f jsonb; r uuid; store uuid; q uuid; evidence uuid; proof uuid; c uuid; op uuid; value jsonb;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid'); r:=(f->>'request_id')::uuid;store:=(f->>'store_id')::uuid;q:=(f->>'quote_id')::uuid;
 PERFORM public.direct_order_approve_photo_payment(store,r,108000,q,(f->>'proof_id')::uuid);
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path) VALUES(r,store,'cashier','attachment','Partial advance cost',store::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg') RETURNING id INTO evidence;
 PERFORM public.direct_order_staff_support_action(store,r,1,'reconcile_delivery_fee',jsonb_build_object('operation_id',gen_random_uuid(),'amount',20000,'provider','grab','reference','advance-cost','evidence_message_id',evidence));
 SELECT id INTO c FROM public.direct_order_payment_charges WHERE request_id=r AND status='pending';
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path,metadata) VALUES(r,store,'customer','payment_proof','Partial transfer',store::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg',jsonb_build_object('quote_id',q,'charge_id',c)) RETURNING id INTO proof;
 PERFORM public.direct_order_record_receipt(store,r,q,proof,10000,'PARTIAL-ADVANCE-001');
 op:=gen_random_uuid();
 value:=public.direct_order_staff_support_action(store,r,(SELECT support_version FROM public.direct_order_requests WHERE id=r),'reconcile_delivery_fee',jsonb_build_object('operation_id',op,'amount',5000,'provider','grab','reference','advance-final','evidence_message_id',evidence));
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_payment_charges WHERE request_id=r AND status='paid' AND amount=10000 AND credited_receipt_ids<>ARRAY[]::uuid[]) OR (value->>'delivery_adjustment_refund_due')::numeric<>5000 THEN RAISE EXCEPTION 'PARTIAL_ADVANCE_NOT_POSTED'; END IF;
 value:=public.direct_order_staff_support_action(store,r,(SELECT support_version FROM public.direct_order_requests WHERE id=r),'refund_delivery_adjustment',jsonb_build_object('operation_id',gen_random_uuid(),'amount',5000,'reference','PARTIAL-ADVANCE-REFUND'));
 IF (value->>'unposted_advance')::numeric<>0 OR (value->>'delivery_adjustment_refund_due')::numeric<>0 OR NOT EXISTS(SELECT 1 FROM public.direct_order_payment_receipts WHERE proof_message_id=proof AND charge_id=c AND amount=10000) THEN RAISE EXCEPTION 'PARTIAL_ADVANCE_RECEIPT_CHANGED'; END IF;
 PERFORM public.direct_order_assert_settled(r);
END; $partial_advance$;
SELECT 'DIRECT_ORDER_VERIFIED_PARTIAL_ADVANCE=PASS';

DO $pickup_after_refund$
DECLARE f jsonb; r uuid; store uuid; q uuid; evidence uuid; proof uuid; charge uuid; session uuid; secret text; offer uuid; value jsonb; remaining numeric;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid'); r:=(f->>'request_id')::uuid;store:=(f->>'store_id')::uuid;q:=(f->>'quote_id')::uuid;
 UPDATE public.direct_order_quotes SET delivery_fee_pretax=20000,delivery_fee_vat=1600,delivery_fee_total=21600,final_total=129600 WHERE id=q;
 PERFORM public.direct_order_approve_photo_payment(store,r,129600,q,(f->>'proof_id')::uuid);
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path) VALUES(r,store,'cashier','attachment','Reduced driver cost',store::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg') RETURNING id INTO evidence;
 -- A mixed refund must attribute 5,000 to the supplement and only 3,600
 -- to the original shipping payment before refunding the pickup remainder.
 PERFORM public.direct_order_staff_support_action(store,r,1,'reconcile_delivery_fee',jsonb_build_object('operation_id',gen_random_uuid(),'amount',26600,'provider','grab','reference','shipping-increase','evidence_message_id',evidence));
 SELECT id INTO charge FROM public.direct_order_payment_charges WHERE request_id=r AND status='pending';
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path,metadata) VALUES(r,store,'customer','payment_proof','Shipping supplement',store::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg',jsonb_build_object('quote_id',q,'charge_id',charge)) RETURNING id INTO proof;
 PERFORM public.direct_order_record_receipt(store,r,q,proof,5000,'SHIPPING-SUPPLEMENT');
 PERFORM public.direct_order_staff_support_action(store,r,(SELECT support_version FROM public.direct_order_requests WHERE id=r),'reconcile_delivery_fee',jsonb_build_object('operation_id',gen_random_uuid(),'amount',18000,'provider','grab','reference','shipping-reduction','evidence_message_id',evidence));
 PERFORM public.direct_order_staff_support_action(store,r,(SELECT support_version FROM public.direct_order_requests WHERE id=r),'refund_delivery_adjustment',jsonb_build_object('operation_id',gen_random_uuid(),'amount',8600,'reference','SHIPPING-REDUCTION-REFUND'));
 IF public.direct_order_original_delivery_refund_remaining(r)<>18000 THEN RAISE EXCEPTION 'ORIGINAL_REFUND_ALLOCATION_WRONG'; END IF;
 SELECT session_id INTO session FROM public.direct_order_requests WHERE id=r;SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=session;
 PERFORM public.direct_order_issue_access(session,secret,r,repeat('f',64));
 value:=public.direct_order_staff_offer_pickup(store,r,(SELECT fulfillment_version FROM public.direct_order_requests WHERE id=r),'Driver unavailable');offer:=(value->'pickup_offer'->>'id')::uuid;
 value:=public.direct_order_public_decide_pickup(session,secret,r,offer,true,true);
 IF (value->'pickup_offer'->>'refund_due')::numeric<>18000 THEN RAISE EXCEPTION 'PICKUP_REFUND_DOUBLE_COUNTED'; END IF;
 UPDATE public.direct_delivery_fulfillment_tickets SET status='ready' WHERE request_id=r;
 PERFORM public.direct_order_cashier_complete_pickup(store,r,(SELECT version FROM public.direct_delivery_fulfillment_tickets WHERE request_id=r));
 PERFORM public.direct_order_resolve_access(r,repeat('f',64));
 PERFORM public.direct_order_staff_record_pickup_refund(store,r,offer,'PICKUP-REMAINDER-REFUND');
 SELECT sum(amount) INTO remaining FROM public.payment_adjustments WHERE payment_id=(SELECT payment_id FROM public.direct_order_financials WHERE request_id=r);
 IF remaining<>21600 THEN RAISE EXCEPTION 'PICKUP_REFUND_AMOUNT_WRONG'; END IF;
 BEGIN PERFORM public.direct_order_resolve_access(r,repeat('f',64));RAISE EXCEPTION 'REFUNDED_PICKUP_LINK_OPEN';EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_ORDER_CLOSED' THEN RAISE; END IF;END;
 UPDATE public.direct_order_requests SET created_at=now()-interval '400 days' WHERE id=r;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(public.direct_order_cleanup_candidates(500)) p WHERE p->>'request_id'=r::text) THEN RAISE EXCEPTION 'SETTLED_PICKUP_NEVER_CLEANED'; END IF;
 PERFORM public.direct_order_cleanup_expired_pii(ARRAY[r]);
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_messages WHERE id=evidence AND attachment_storage_path IS NULL AND body='DIRECT_ORDER_EVIDENCE_PURGED')
  OR NOT EXISTS(SELECT 1 FROM public.direct_order_delivery_cost_changes WHERE request_id=r AND evidence_message_id=evidence)
  OR NOT EXISTS(SELECT 1 FROM public.direct_order_financials WHERE request_id=r) THEN RAISE EXCEPTION 'COST_RETENTION_LOST_LEDGER'; END IF;
END; $pickup_after_refund$;
SELECT 'DIRECT_ORDER_PICKUP_NET_REFUND_AND_LINK=PASS';
