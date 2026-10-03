-- Real direct approval + process_payment; disposable DB only.
\set ON_ERROR_STOP on
BEGIN;
CREATE FUNCTION photo_test.expect_blocked(f jsonb,p_error text) RETURNS void LANGUAGE plpgsql AS $$
DECLARE e text;
BEGIN
 BEGIN PERFORM photo_test.approve(f); EXCEPTION WHEN OTHERS THEN e:=SQLERRM; END;
 IF e IS DISTINCT FROM p_error THEN RAISE EXCEPTION 'EXPECTED_%,GOT_%',p_error,e; END IF;
 PERFORM photo_test.assert_empty_graph((f->>'request_id')::uuid);
END $$;
DO $$
DECLARE f jsonb; r jsonb; replay jsonb; v_photo uuid; e text;
BEGIN
 IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM public.sepay_transactions) THEN RAISE EXCEPTION 'TEST_REQUIRES_NO_SEPAY_DATA'; END IF;
 f:=photo_test.create_request();
 PERFORM photo_test.assert_empty_graph((f->>'request_id')::uuid);
 r:=photo_test.approve(f); replay:=photo_test.approve(f);
 IF (r->>'idempotent')::boolean OR NOT (replay->>'idempotent')::boolean
 OR r->>'payment_id'<>replay->>'payment_id' OR r->>'ticket_id'<>replay->>'ticket_id' THEN
 RAISE EXCEPTION 'PHOTO_APPROVAL_RETRY_NOT_IDEMPOTENT'; END IF;
 PERFORM photo_test.assert_single_graph((f->>'request_id')::uuid);

 f:=photo_test.create_request(true,'store_prepaid');
 PERFORM photo_test.approve(f);
 PERFORM photo_test.assert_single_graph((f->>'request_id')::uuid);

 f:=photo_test.create_request(true,'not_applicable','pickup');
 PERFORM photo_test.approve(f);
 PERFORM photo_test.assert_single_graph((f->>'request_id')::uuid);
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_financials f2 JOIN public.orders o ON o.id=f2.order_id
 WHERE f2.request_id=(f->>'request_id')::uuid AND f2.delivery_payment_mode='not_applicable'
 AND o.sales_channel='takeaway' AND o.notes LIKE 'Direct pickup %') THEN
 RAISE EXCEPTION 'PHOTO_APPROVAL_LOST_PICKUP_PROVENANCE'; END IF;

 f:=photo_test.create_request();
 UPDATE public.direct_order_requests SET state='rejected' WHERE id=(f->>'request_id')::uuid;
 PERFORM photo_test.expect_blocked(f,'DIRECT_ORDER_REQUEST_NOT_APPROVABLE');
 f:=photo_test.create_request();
 PERFORM set_config('direct_order.test_local_time','22:00',true);
 PERFORM photo_test.expect_blocked(f,'DIRECT_ORDER_APPROVAL_CUTOFF');
 PERFORM set_config('direct_order.test_local_time','12:00',true);
 UPDATE public.direct_order_storefronts SET is_paused=true;
 PERFORM photo_test.approve(f);
 PERFORM photo_test.assert_single_graph((f->>'request_id')::uuid);
 UPDATE public.direct_order_storefronts SET is_paused=false;

 -- Printing failure is best effort and cannot undo payment or kitchen delivery.
 f:=photo_test.create_request();
 PERFORM set_config('photo_test.receipt_failure','on',true);
 PERFORM photo_test.approve(f);
 PERFORM photo_test.assert_single_graph((f->>'request_id')::uuid);
 IF NOT EXISTS(SELECT 1 FROM public.audit_logs WHERE entity_id=(f->>'request_id')::uuid AND action='direct_order_customer_receipt_queue_failed') THEN
 RAISE EXCEPTION 'RECEIPT_QUEUE_FAILURE_NOT_RECORDED'; END IF;
 PERFORM set_config('photo_test.receipt_failure','off',true);

 f:=photo_test.create_request(false);
 PERFORM photo_test.expect_blocked(f,'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED');
 f:=photo_test.create_request();
 PERFORM photo_test.expect_blocked(f||jsonb_build_object('quote_id',gen_random_uuid()),'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED');
 PERFORM photo_test.expect_blocked(f||jsonb_build_object('proof_id',gen_random_uuid()),'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED');
 UPDATE public.direct_order_messages SET metadata=jsonb_build_object('quote_id',gen_random_uuid(),'quote_version',1)
 WHERE id=(f->>'proof_id')::uuid;
 PERFORM photo_test.expect_blocked(f,'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED');

 f:=photo_test.create_request();
 UPDATE public.direct_order_messages SET message_type='text',attachment_storage_path=NULL,body='No payment photo' WHERE id=(f->>'proof_id')::uuid;
 PERFORM photo_test.expect_blocked(f,'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED');
 f:=photo_test.create_request();
 UPDATE public.direct_order_messages SET metadata=metadata||jsonb_build_object('quote_version',2) WHERE id=(f->>'proof_id')::uuid;
 PERFORM photo_test.expect_blocked(f,'DIRECT_ORDER_PAYMENT_PROOF_REQUIRED');

 f:=photo_test.create_request();
 INSERT INTO public.direct_order_proof_review_requests(request_id,restaurant_id,quote_id,target_message_id,reason_code,requested_by)
 VALUES((f->>'request_id')::uuid,(f->>'store_id')::uuid,(f->>'quote_id')::uuid,(f->>'proof_id')::uuid,'blurry',auth.uid());
 PERFORM photo_test.expect_blocked(f,'DIRECT_ORDER_PROOF_RESUBMISSION_PENDING');

 f:=photo_test.create_request();
 e:=NULL;
 BEGIN
  PERFORM public.direct_order_approve_photo_payment((f->>'store_id')::uuid,(f->>'request_id')::uuid,108001,(f->>'quote_id')::uuid,(f->>'proof_id')::uuid);
 EXCEPTION WHEN OTHERS THEN e:=SQLERRM; END;
 IF e IS DISTINCT FROM 'DIRECT_ORDER_PAYMENT_AMOUNT_MISMATCH' THEN RAISE EXCEPTION 'AMOUNT_MISMATCH_NOT_BLOCKED:%',e; END IF;
 PERFORM photo_test.assert_empty_graph((f->>'request_id')::uuid);

 PERFORM photo_test.expect_blocked(f||jsonb_build_object('store_id',gen_random_uuid()),'DIRECT_ORDER_FORBIDDEN');
 UPDATE public.users SET role='kitchen' WHERE auth_id=auth.uid();
 PERFORM photo_test.expect_blocked(f,'DIRECT_ORDER_FORBIDDEN');
 UPDATE public.users SET role='cashier' WHERE auth_id=auth.uid();
 PERFORM set_config('request.jwt.claim.sub',gen_random_uuid()::text,true);
 PERFORM photo_test.expect_blocked(f,'DIRECT_ORDER_FORBIDDEN');
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);

 -- Replacement photo must be reviewed explicitly; old photo IDs cannot win.
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,attachment_storage_path,metadata,created_at)
 SELECT request_id,restaurant_id,sender_type,message_type,restaurant_id::text||'/'||request_id::text||'/'||gen_random_uuid()::text||'.jpg',metadata,now()+interval '1 second'
 FROM public.direct_order_messages WHERE id=(f->>'proof_id')::uuid RETURNING id INTO v_photo;
 PERFORM photo_test.expect_blocked(f,'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED');
 f:=f||jsonb_build_object('proof_id',v_photo);
 PERFORM photo_test.approve(f);
 PERFORM photo_test.assert_single_graph((f->>'request_id')::uuid);
END $$;

-- Inject a real payment insert failure after order/ticket creation.
CREATE FUNCTION photo_test.fail_payment() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN RAISE EXCEPTION 'PHOTO_TEST_PAYMENT_INSERT_FAILED'; END $$;
CREATE TRIGGER photo_test_fail BEFORE INSERT ON public.payments FOR EACH ROW EXECUTE FUNCTION photo_test.fail_payment();
DO $$
DECLARE f jsonb:=photo_test.create_request(); v_stock numeric;
BEGIN
 SELECT current_stock INTO v_stock FROM public.inventory_items LIMIT 1;
 PERFORM photo_test.expect_blocked(f,'PHOTO_TEST_PAYMENT_INSERT_FAILED');
 IF v_stock IS DISTINCT FROM (SELECT current_stock FROM public.inventory_items LIMIT 1)
 OR EXISTS(SELECT 1 FROM public.audit_logs WHERE entity_id=(f->>'request_id')::uuid AND action='direct_order_payment_approved') THEN
 RAISE EXCEPTION 'FAILED_PAYMENT_DID_NOT_ROLL_BACK'; END IF;
END $$;
DROP TRIGGER photo_test_fail ON public.payments;
ROLLBACK;
