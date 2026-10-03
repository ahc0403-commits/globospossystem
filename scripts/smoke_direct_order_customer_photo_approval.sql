-- Production smoke using a synthetic copy of a reviewed request. Everything,
-- including payment, stock, receipt queue and kitchen writes, is rolled back.
-- Supply photo_smoke_request_id through psql. Never approve the source request.
\set ON_ERROR_STOP on
BEGIN;
SELECT set_config('photo_smoke.source_request_id', :'photo_smoke_request_id', true);
DO $smoke$
DECLARE
 source_request public.direct_order_requests%ROWTYPE;
 source_quote public.direct_order_quotes%ROWTYPE;
 source_item public.direct_order_request_items%ROWTYPE;
 v_session_id uuid:=gen_random_uuid(); v_request_id uuid:=gen_random_uuid();
 v_quote_id uuid:=gen_random_uuid(); v_proof_id uuid:=gen_random_uuid();
 actor_id uuid; actor_claims jsonb; kitchen_id uuid; kitchen_claims jsonb;
 result jsonb; retry jsonb; kitchen_rows jsonb; stock_after jsonb; stock_retry jsonb;
 ticket public.direct_delivery_fulfillment_tickets%ROWTYPE;
 item_count integer;
BEGIN
 SELECT * INTO STRICT source_request FROM public.direct_order_requests
 WHERE id=current_setting('photo_smoke.source_request_id')::uuid;
 SELECT * INTO STRICT source_quote FROM public.direct_order_quotes
 WHERE request_id=source_request.id AND status='locked' ORDER BY version DESC LIMIT 1;
 SELECT auth_user.id,jsonb_build_object('sub',auth_user.id,'role','authenticated','app_metadata',auth_user.raw_app_meta_data)
 INTO STRICT actor_id,actor_claims FROM auth.users auth_user
 JOIN public.users profile ON profile.auth_id=auth_user.id
 WHERE profile.role='cashier' AND profile.is_active AND profile.restaurant_id=source_request.restaurant_id
 ORDER BY (auth_user.email='bt_pos1@globos.world') DESC,auth_user.id LIMIT 1;
 SELECT auth_user.id,jsonb_build_object('sub',auth_user.id,'role','authenticated','app_metadata',auth_user.raw_app_meta_data)
 INTO STRICT kitchen_id,kitchen_claims FROM auth.users auth_user
 JOIN public.users profile ON profile.auth_id=auth_user.id
 WHERE profile.role='kitchen' AND profile.is_active AND profile.restaurant_id=source_request.restaurant_id
 ORDER BY auth_user.id LIMIT 1;
 INSERT INTO public.direct_order_sessions(id,restaurant_id,secret_hash,locale)
 VALUES(v_session_id,source_request.restaurant_id,repeat(replace(gen_random_uuid()::text,'-',''),2),source_request.locale);
 INSERT INTO public.direct_order_requests(id,restaurant_id,session_id,client_request_id,reference_code,state,locale,fulfillment_type,customer_note)
 VALUES(v_request_id,source_request.restaurant_id,v_session_id,gen_random_uuid(),
 'D'||upper(left(replace(gen_random_uuid()::text,'-',''),8)),
 'awaiting_payment_review',source_request.locale,source_request.fulfillment_type,'PHOTO RELEASE SMOKE - ROLLBACK ONLY');
 FOR source_item IN SELECT * FROM public.direct_order_request_items WHERE direct_order_request_items.request_id=source_request.id LOOP
  INSERT INTO public.direct_order_request_items
  SELECT (jsonb_populate_record(NULL::public.direct_order_request_items,to_jsonb(source_item)||jsonb_build_object('id',gen_random_uuid(),'request_id',v_request_id))).*;
 END LOOP;
 SELECT count(*) INTO item_count FROM public.direct_order_request_items WHERE direct_order_request_items.request_id=v_request_id;
 INSERT INTO public.direct_order_quotes
 SELECT (jsonb_populate_record(NULL::public.direct_order_quotes,to_jsonb(source_quote)||jsonb_build_object('id',v_quote_id,'request_id',v_request_id,'created_by',actor_id))).*;
 INSERT INTO public.direct_order_messages(id,request_id,restaurant_id,sender_type,message_type,attachment_storage_path,metadata)
 VALUES(v_proof_id,v_request_id,source_request.restaurant_id,'customer','payment_proof',
 source_request.restaurant_id::text||'/'||v_request_id::text||'/'||gen_random_uuid()::text||'.jpg',
 jsonb_build_object('quote_id',v_quote_id,'quote_version',source_quote.version));
 IF EXISTS(SELECT 1 FROM public.direct_order_financials f WHERE f.request_id=v_request_id)
 OR EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets t WHERE t.request_id=v_request_id) THEN
 RAISE EXCEPTION 'PHOTO_SMOKE_UPLOAD_AUTO_APPROVED'; END IF;
 PERFORM set_config('request.jwt.claim.sub',actor_id::text,true);
 PERFORM set_config('request.jwt.claims',actor_claims::text,true);
 EXECUTE 'SET LOCAL ROLE authenticated';
 result:=public.direct_order_approve_photo_payment(source_request.restaurant_id,v_request_id,source_quote.final_total,v_quote_id,v_proof_id);
 EXECUTE 'SET LOCAL ROLE postgres';
 SELECT * INTO STRICT ticket FROM public.direct_delivery_fulfillment_tickets WHERE id=(result->>'ticket_id')::uuid;
 IF (SELECT count(*) FROM public.direct_delivery_fulfillment_ticket_items WHERE ticket_id=ticket.id)<>item_count
 OR (SELECT count(*) FROM public.payments WHERE order_id=(result->>'order_id')::uuid)<>1
 OR NOT EXISTS(SELECT 1 FROM public.direct_order_financials f WHERE f.request_id=v_request_id AND f.final_total=source_quote.final_total AND f.delivery_payment_mode=source_quote.delivery_payment_mode) THEN
 RAISE EXCEPTION 'PHOTO_SMOKE_FINANCIAL_KITCHEN_MISMATCH'; END IF;
 SELECT jsonb_object_agg(i.id,i.current_stock) INTO stock_after FROM public.inventory_items i
 WHERE i.id IN (SELECT tx.ingredient_id FROM public.inventory_transactions tx JOIN public.order_items oi ON oi.id=tx.reference_id WHERE oi.order_id=(result->>'order_id')::uuid);
 EXECUTE 'SET LOCAL ROLE authenticated';
 retry:=public.direct_order_approve_photo_payment(source_request.restaurant_id,v_request_id,source_quote.final_total,v_quote_id,v_proof_id);
 EXECUTE 'SET LOCAL ROLE postgres';
 SELECT jsonb_object_agg(i.id,i.current_stock) INTO stock_retry FROM public.inventory_items i
 WHERE i.id IN (SELECT tx.ingredient_id FROM public.inventory_transactions tx JOIN public.order_items oi ON oi.id=tx.reference_id WHERE oi.order_id=(result->>'order_id')::uuid);
 IF NOT (retry->>'idempotent')::boolean OR result->>'payment_id'<>retry->>'payment_id'
 OR result->>'ticket_id'<>retry->>'ticket_id' OR stock_after IS DISTINCT FROM stock_retry THEN
 RAISE EXCEPTION 'PHOTO_SMOKE_DUPLICATED_PAYMENT_OR_STOCK'; END IF;
 PERFORM set_config('request.jwt.claim.sub',kitchen_id::text,true);
 PERFORM set_config('request.jwt.claims',kitchen_claims::text,true);
 EXECUTE 'SET LOCAL ROLE authenticated';
 kitchen_rows:=public.direct_delivery_ticket_list(source_request.restaurant_id,NULL,ticket.created_at-interval '1 second','00000000-0000-0000-0000-000000000000',200);
 EXECUTE 'SET LOCAL ROLE postgres';
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(kitchen_rows) entry WHERE entry->>'id'=ticket.id::text AND jsonb_array_length(entry->'items')=item_count) THEN
 RAISE EXCEPTION 'PHOTO_SMOKE_KITCHEN_ROLE_CANNOT_READ_TICKET'; END IF;
 RAISE NOTICE 'PHOTO_APPROVAL_PRODUCTION_SMOKE=PASS amount=% items=% kitchen_role=PASS retry=PASS; all synthetic writes rolled back',source_quote.final_total,item_count;
END;
$smoke$;
ROLLBACK;
