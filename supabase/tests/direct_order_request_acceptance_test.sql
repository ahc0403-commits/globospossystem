\set ON_ERROR_STOP on
DO $$ BEGIN IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF; END $$;
SELECT set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',false);
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}',false);
DO $test$
DECLARE f jsonb; shop uuid; rid uuid; q uuid; iid uuid; v integer; mutation uuid:=gen_random_uuid(); result jsonb; n int;
BEGIN
 f:=proof_test.scope(false);shop:=(f->>'store_id')::uuid;rid:=(f->>'request_id')::uuid;
 UPDATE public.direct_order_quotes SET status='superseded' WHERE request_id=rid;
 UPDATE public.direct_order_requests SET state='awaiting_quote',customer_note='Private cashier acceptance fixture' WHERE id=rid;
 SELECT id,version INTO q,v FROM public.direct_order_customer_requirements WHERE request_id=rid AND source_kind='order';
 result:=public.direct_order_staff_accept_requirement(shop,rid,q,v,mutation);
 ASSERT (SELECT status='confirmed' AND NOT needs_confirmation FROM public.direct_order_customer_requirements WHERE id=q),'ACCEPT_STILL_REQUIRES_CUSTOMER';
 SELECT count(*) INTO n FROM public.direct_order_messages WHERE request_id=rid;
 PERFORM public.direct_order_staff_accept_requirement(shop,rid,q,v,mutation);
 ASSERT (SELECT count(*)=n FROM public.direct_order_messages WHERE request_id=rid),'ACCEPT_RETRY_DUPLICATED_MESSAGE';
 result:=public.direct_order_staff_attachment_context(shop,rid);
 ASSERT result->'support'->>'chat_open'='true','STAFF_ATTACHMENT_OPEN_REJECTED';
 ASSERT (SELECT count(*)=1 FROM jsonb_object_keys(result)),'ATTACHMENT_AUTH_RETURNED_CHAT_HISTORY';
 SELECT id INTO iid FROM public.direct_order_request_items WHERE request_id=rid LIMIT 1;
 UPDATE public.direct_order_request_items SET item_note='Sauce separate fixture' WHERE id=iid;
 SELECT id,version INTO q,v FROM public.direct_order_customer_requirements WHERE request_id=rid AND source_kind='item';
 PERFORM public.direct_order_staff_accept_requirement(shop,rid,q,v,gen_random_uuid());
 ASSERT (SELECT status='confirmed' AND print_reply_vi=request_text AND print_request_vi=request_text FROM public.direct_order_customer_requirements WHERE id=q),'COOKING_INSTRUCTION_REPLACED_BY_ACK';
 ASSERT (public.direct_order_requirement_print_snapshot(rid,'preparation')->'confirmed_requirements'->0->>'reply_text') IS NULL,'CASHIER_REPLY_EXPORTED_TO_KITCHEN';
 -- A changed source invalidates the prior acceptance and stale request version.
 UPDATE public.direct_order_request_items SET item_note='New sauce fixture' WHERE id=iid;
 BEGIN PERFORM public.direct_order_staff_accept_requirement(shop,rid,q,v,gen_random_uuid()); RAISE EXCEPTION 'STALE_ACCEPT_ALLOWED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'DIRECT_ORDER_REQUIREMENT_VERSION_CONFLICT' THEN RAISE; END IF; END;
 SELECT version INTO v FROM public.direct_order_customer_requirements WHERE id=q;
 PERFORM public.direct_order_staff_accept_requirement(shop,rid,q,v,gen_random_uuid());
 PERFORM public.direct_order_staff_quote_with_payment_mode(shop,rid,0,NULL,'customer_direct');
 ASSERT (SELECT state='quoted' FROM public.direct_order_requests WHERE id=rid),'QUOTE_BLOCKED_AFTER_ACCEPT';
 UPDATE public.direct_order_requests SET support_closed_at=clock_timestamp() WHERE id=rid;
 ASSERT public.direct_order_staff_attachment_context(shop,rid)->'support'->>'chat_open'='false','CLOSED_CHAT_CAN_UPLOAD';
 BEGIN PERFORM public.direct_order_staff_attachment_context(gen_random_uuid(),rid); RAISE EXCEPTION 'OTHER_STORE_ALLOWED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM NOT IN('DIRECT_ORDER_REQUEST_NOT_FOUND','DIRECT_ORDER_FORBIDDEN') THEN RAISE; END IF; END;
 RAISE NOTICE 'DIRECT_ORDER_ACCEPTANCE=PASS immediate_confirmation idempotent quote_ready stale_source bounded_attachment closed_chat store_isolation';
END $test$;
