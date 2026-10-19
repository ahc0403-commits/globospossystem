DO $money$
DECLARE f jsonb;r uuid;s uuid;q uuid;proof uuid;e uuid;op uuid;v jsonb;actual numeric;applied numeric;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid');r:=(f->>'request_id')::uuid;s:=(f->>'store_id')::uuid;q:=(f->>'quote_id')::uuid;proof:=(f->>'proof_id')::uuid;
 v:=public.direct_order_record_receipt(s,r,q,proof,120000,'EXCESS-BANK-1');
 SELECT actual_amount,amount INTO actual,applied FROM public.direct_order_payment_receipts WHERE proof_message_id=proof;
 IF actual<>120000 OR applied<>108000 OR (v->>'overpayment_due')::numeric<>12000 THEN RAISE EXCEPTION 'OVERPAYMENT_ALLOCATION_WRONG %',v; END IF;
 PERFORM public.direct_order_record_receipt(s,r,q,proof,120000,'EXCESS-BANK-1');
 PERFORM photo_test.assert_single_graph(r);
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path) VALUES(r,s,'cashier','attachment','Refund transfer',s::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg') RETURNING id INTO e;
 op:=gen_random_uuid();
 v:=public.direct_order_staff_support_action(s,r,(v->>'version')::int,'refund_overpayment',jsonb_build_object('operation_id',op,'amount',12000,'reference','REFUND-1','method','BANKTRANSFER','evidence_message_id',e));
 IF (v->>'overpayment_due')::numeric<>0 OR EXISTS(SELECT 1 FROM public.payment_adjustments WHERE payment_id=(SELECT payment_id FROM public.direct_order_financials WHERE request_id=r)) THEN RAISE EXCEPTION 'EXCESS_REFUND_REVERSED_REVENUE'; END IF;
 PERFORM public.direct_order_staff_support_action(s,r,0,'refund_overpayment',jsonb_build_object('operation_id',op,'amount',12000,'reference','REFUND-1','method','BANKTRANSFER','evidence_message_id',e));
 IF (SELECT count(*) FROM public.direct_order_refund_records WHERE id=op)<>1 THEN RAISE EXCEPTION 'REFUND_RETRY_DUPLICATED'; END IF;
END; $money$;
SELECT 'DIRECT_ORDER_MONEY_RECONCILIATION=PASS';
DO $cash$
DECLARE f jsonb;r uuid;s uuid;q uuid;proof uuid;e uuid;op uuid;recovery uuid;v jsonb;before_cash numeric;amount numeric;ver int;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid');r:=(f->>'request_id')::uuid;s:=(f->>'store_id')::uuid;q:=(f->>'quote_id')::uuid;proof:=(f->>'proof_id')::uuid;
 UPDATE public.users SET role='admin' WHERE auth_id=auth.uid();
 v:=public.direct_order_record_receipt(s,r,q,proof,115000,'CASH-EXCESS-BANK');
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path) VALUES(r,s,'cashier','attachment','Cash handoff evidence',s::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg') RETURNING id INTO e;
 PERFORM public.direct_order_staff_support_action(s,r,(v->>'version')::int,'reconcile_delivery_fee',jsonb_build_object('operation_id',gen_random_uuid(),'amount',0,'provider','grab','reference','FREE-DELIVERY','evidence_message_id',e));
 -- Use a paid delivery cost for driver cash verification, collected via its exact supplemental charge.
 v:=public.direct_order_staff_support_action(s,r,(SELECT support_version FROM public.direct_order_requests WHERE id=r),'reconcile_delivery_fee',jsonb_build_object('operation_id',gen_random_uuid(),'amount',10000,'provider','grab','reference','DRIVER-FEE','evidence_message_id',e));
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path,metadata)
 SELECT r,s,'customer','payment_proof','delivery fee',s::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg',jsonb_build_object('quote_id',q,'charge_id',id) FROM public.direct_order_payment_charges WHERE request_id=r AND status='pending' RETURNING id INTO proof;
 PERFORM public.direct_order_record_receipt(s,r,q,proof,10000,'CASH-DELIVERY-BANK');
 UPDATE public.direct_delivery_fulfillment_tickets SET status='ready' WHERE request_id=r;
 SELECT version INTO ver FROM public.direct_delivery_fulfillment_tickets WHERE request_id=r;
 BEGIN PERFORM public.direct_order_set_dispatch_v3(s,r,ver,'grab',NULL,10000,NULL,'0901234567');RAISE EXCEPTION 'UNCONFIRMED_CASH_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_CASH_PAYOUT_CONFIRMATION_REQUIRED' THEN RAISE; END IF; END;
 op:=gen_random_uuid();
 PERFORM public.direct_order_set_dispatch_v4(s,r,ver,'grab',NULL,10000,NULL,'0901234567',true,e,op,'DRIVER-HANDOFF');
 PERFORM public.direct_order_set_dispatch_v4(s,r,ver,'grab',NULL,10000,NULL,'0901234567',true,e,op,'DRIVER-HANDOFF');
 IF (SELECT count(*) FROM public.direct_order_driver_cash_movements WHERE request_id=r AND reason='handoff')<>1 THEN RAISE EXCEPTION 'CASH_HANDOFF_DUPLICATED'; END IF;
 IF (SELECT reference FROM public.direct_order_driver_cash_movements WHERE id=op)<>'DRIVER-HANDOFF' THEN RAISE EXCEPTION 'CASH_REFERENCE_LOST'; END IF;
 BEGIN PERFORM public.direct_order_set_dispatch_v4(s,r,ver,'grab',NULL,10000,NULL,'0901234567',true,e,op,'CHANGED');RAISE EXCEPTION 'CHANGED_CASH_REPLAY_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_CASH_PAYOUT_LOCKED' THEN RAISE; END IF; END;
 BEGIN UPDATE public.direct_order_dispatches SET actual_grab_fee=11000 WHERE request_id=r;RAISE EXCEPTION 'OLD_DISPATCH_MONEY_MUTABLE';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_CASH_PAYOUT_LOCKED' THEN RAISE; END IF; END;
 recovery:=gen_random_uuid();
 PERFORM public.direct_order_staff_driver_cash_action(s,r,recovery,'recovery',2000,'returned cash',e,op,'CASH');
 PERFORM public.direct_order_staff_driver_cash_action(s,r,recovery,'recovery',2000,'returned cash',e,op,'CASH');
 PERFORM public.direct_order_staff_driver_cash_action(s,r,gen_random_uuid(),'recovery',1000,'returned bank',e,op,'BANKTRANSFER');
 BEGIN PERFORM public.direct_order_staff_driver_cash_action(s,r,gen_random_uuid(),'recovery',8000,'too much',e,op,'CASH');RAISE EXCEPTION 'OVER_RECOVERY_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_CASH_MOVEMENT_INVALID' THEN RAISE; END IF; END;
 v:=public.get_daily_closing_cash_preview(s,NULL);
 before_cash:=(v->>'expected_cash_amount')::numeric;
 PERFORM public.direct_order_staff_support_action(s,r,(SELECT support_version FROM public.direct_order_requests WHERE id=r),'refund_overpayment',jsonb_build_object('operation_id',gen_random_uuid(),'amount',7000,'reference','cash excess refund','method','CASH','evidence_message_id',e));
 v:=public.get_daily_closing_cash_preview(s,NULL);
 IF (v->>'expected_cash_amount')::numeric<>before_cash-7000 OR (v->>'direct_order_cash_refunds')::numeric<7000 THEN RAISE EXCEPTION 'CASH_REFUND_NOT_DEDUCTED %',v; END IF;
 IF (SELECT sum(actual_grab_fee) FROM public.direct_order_cash_payout_entries WHERE request_id=r)<>8000 THEN RAISE EXCEPTION 'BANK_RECOVERY_CHANGED_SAFE_CASH'; END IF;
 v:=public.create_daily_closing(s,'Money test','{}',5000000,NULL);
 SELECT expected_cash_amount INTO amount FROM public.daily_closings WHERE restaurant_id=s AND closing_date=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date;
 IF amount<>before_cash-7000 THEN RAISE EXCEPTION 'CLOSING_CASH_WRONG'; END IF;
 PERFORM * FROM public.get_daily_closing_days(s,1);
 BEGIN UPDATE public.direct_order_driver_cash_movements SET amount=1 WHERE id=op;RAISE EXCEPTION 'CASH_HISTORY_MUTABLE';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_MONEY_IMMUTABLE' THEN RAISE; END IF; END;
 UPDATE public.users SET role='cashier' WHERE auth_id=auth.uid();
END; $cash$;
SELECT 'DIRECT_ORDER_DRIVER_CASH_AND_CLOSING=PASS';
DO $cancel$
DECLARE f jsonb;r uuid;s uuid;v jsonb;e uuid;q uuid;proof uuid;op uuid;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid');r:=(f->>'request_id')::uuid;s:=(f->>'store_id')::uuid;q:=(f->>'quote_id')::uuid;proof:=(f->>'proof_id')::uuid;
 v:=public.direct_order_record_receipt(s,r,q,proof,120000,'CANCEL-EXCESS');
 v:=public.direct_order_staff_support_action(s,r,(v->>'version')::int,'cancel_order','{}');
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path) VALUES(r,s,'cashier','attachment','Refund evidence',s::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg') RETURNING id INTO e;
 op:=gen_random_uuid();
 v:=public.direct_order_staff_support_action(s,r,(v->>'version')::int,'refund_complete',jsonb_build_object('operation_id',op,'amount',120000,'reference','full cancellation refund','method','BANKTRANSFER','evidence_message_id',e));
 IF (v->>'refund_due')::numeric<>0 OR (SELECT overpayment_amount FROM public.direct_order_refund_records WHERE id=op)<>12000 THEN RAISE EXCEPTION 'CANCELLATION_EXCESS_WRONG %',v; END IF;
 IF (SELECT sum(a.amount) FROM public.payment_adjustments a JOIN public.direct_order_financials f ON f.payment_id=a.payment_id WHERE f.request_id=r)<>108000 THEN RAISE EXCEPTION 'EXCESS_REVERSED_AS_REVENUE'; END IF;
END; $cancel$;
SELECT 'DIRECT_ORDER_CANCELLATION_EXCESS=PASS';
DO $short_payment$
DECLARE f jsonb;r uuid;s uuid;q uuid;proof uuid;v jsonb;charge uuid;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid');r:=(f->>'request_id')::uuid;s:=(f->>'store_id')::uuid;q:=(f->>'quote_id')::uuid;proof:=(f->>'proof_id')::uuid;
 v:=public.direct_order_record_receipt(s,r,q,proof,100000,'SHORT-FIRST');
 PERFORM photo_test.assert_empty_graph(r);
 IF (v->>'food_due')::numeric<>8000 THEN RAISE EXCEPTION 'BALANCE_NOT_ACTUAL_REMAINDER'; END IF;
 BEGIN PERFORM public.direct_order_staff_support_action(s,r,(v->>'version')::int,'charge',jsonb_build_object('kind','food_balance','amount',9000,'reason','Wrong balance'));RAISE EXCEPTION 'ARBITRARY_FOOD_BALANCE_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_CHARGE_AMOUNT_INVALID' THEN RAISE; END IF; END;
 v:=public.direct_order_staff_support_action(s,r,(v->>'version')::int,'charge',jsonb_build_object('kind','food_balance','amount',8000,'reason','Outstanding balance'));
 SELECT id INTO charge FROM public.direct_order_payment_charges WHERE request_id=r AND kind='food_balance' AND status='pending';
 v:=public.direct_order_commit_attachment(r,s,'customer',NULL,s::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg','topup.jpg',charge);
 proof:=(v->>'message_id')::uuid;
 v:=public.direct_order_record_receipt(s,r,q,proof,10000,'SHORT-SECOND');
 PERFORM photo_test.assert_single_graph(r);
 IF (v->>'food_due')::numeric<>0 OR (v->>'overpayment_due')::numeric<>2000 OR (v->>'actual_received')::numeric<>110000 THEN RAISE EXCEPTION 'SECOND_RECEIPT_ALLOCATION_WRONG %',v; END IF;
END; $short_payment$;
SELECT 'DIRECT_ORDER_UNDERPAYMENT_AND_TOPUP=PASS';
DO $access_and_retention$
DECLARE f jsonb;other jsonb;r uuid;s uuid;q uuid;proof uuid;e uuid;sid uuid;other_sid uuid;hash text;other_hash text;v jsonb;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid');r:=(f->>'request_id')::uuid;s:=(f->>'store_id')::uuid;q:=(f->>'quote_id')::uuid;proof:=(f->>'proof_id')::uuid;
 v:=public.direct_order_record_receipt(s,r,q,proof,120000,'ACCESS-EXCESS');
 -- This fixture has no shipping charge; close its shipping decision first.
 UPDATE public.direct_order_requests SET delivery_fee_finalized=true WHERE id=r;
 UPDATE public.direct_delivery_fulfillment_tickets SET status='completed' WHERE request_id=r;
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=r;
 SELECT secret_hash INTO hash FROM public.direct_order_sessions WHERE id=sid;
 IF NOT public.direct_order_access_is_open(r) THEN RAISE EXCEPTION 'EXCESS_CUSTOMER_ACCESS_CLOSED'; END IF;
 v:=public.direct_order_public_refund_details(sid,hash,r,jsonb_build_object('bank','Fixture Bank','account','fixture','holder','Fixture'));
 IF v?'driver_cash' OR v->'refund_account'->>'holder'<>'Fixture' THEN RAISE EXCEPTION 'PUBLIC_REFUND_SCOPE_WRONG'; END IF;
 other:=photo_test.create_request();
 SELECT session_id INTO other_sid FROM public.direct_order_requests WHERE id=(other->>'request_id')::uuid;
 SELECT secret_hash INTO other_hash FROM public.direct_order_sessions WHERE id=other_sid;
 BEGIN PERFORM public.direct_order_public_refund_details(other_sid,other_hash,r,jsonb_build_object('bank','Other Bank','account','other','holder','Other'));RAISE EXCEPTION 'FOREIGN_REFUND_ACCOUNT_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_SUPPORT_INPUT_INVALID' THEN RAISE; END IF; END;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path)
 VALUES(r,s,'cashier','attachment','Refund evidence',s::text||'/'||r::text||'/'||gen_random_uuid()::text||'.jpg') RETURNING id INTO e;
 v:=public.direct_order_staff_support_action(s,r,(v->>'version')::int,'refund_overpayment',jsonb_build_object('operation_id',gen_random_uuid(),'amount',12000,'reference','access refund','method','BANKTRANSFER','evidence_message_id',e));
 IF NOT public.direct_order_access_is_open(r) THEN RAISE EXCEPTION 'REFUND_PHOTO_ACCESS_CLOSED_EARLY'; END IF;
 UPDATE public.direct_order_requests SET support_closed_at=now(),created_at=now()-interval '100 days' WHERE id=r;
 UPDATE public.direct_order_sessions SET created_at=now()-interval '100 days',expires_at=now()-interval '40 days' WHERE id=sid;
 IF public.direct_order_access_is_open(r) THEN RAISE EXCEPTION 'CLOSED_SUPPORT_ACCESS_OPEN'; END IF;
 PERFORM public.direct_order_cleanup_expired_pii(ARRAY[r]);
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_payment_receipts WHERE request_id=r)
 OR NOT EXISTS(SELECT 1 FROM public.direct_order_refund_evidence WHERE request_id=r)
 OR NOT EXISTS(SELECT 1 FROM public.direct_order_sessions WHERE id=sid)
 OR NOT EXISTS(SELECT 1 FROM public.direct_order_messages WHERE id=e AND attachment_storage_path IS NULL AND body='DIRECT_ORDER_EVIDENCE_PURGED')
 OR NOT EXISTS(SELECT 1 FROM public.direct_order_requests WHERE id=r AND pii_purged_at IS NOT NULL AND refund_details='{}')
 THEN RAISE EXCEPTION 'FINANCIAL_RETENTION_OR_PII_PURGE_WRONG'; END IF;
END; $access_and_retention$;
SELECT 'DIRECT_ORDER_REFUND_ACCESS_AND_FINANCIAL_RETENTION=PASS';
