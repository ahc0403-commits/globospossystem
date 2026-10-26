\set ON_ERROR_STOP on
DO $$ BEGIN
 IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
END $$;
SELECT set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',false);
SELECT set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}',false);
UPDATE public.users SET role='cashier',restaurant_id='d1000000-0000-4000-8000-000000000002'
 WHERE auth_id=auth.uid();
UPDATE public.direct_order_storefronts SET is_enabled=true,is_paused=false,ordering_hours_enforced=false
 WHERE restaurant_id='d1000000-0000-4000-8000-000000000002';
CREATE SCHEMA proof_test;
CREATE FUNCTION proof_test.scope(p_photo boolean DEFAULT true) RETURNS jsonb LANGUAGE plpgsql AS $$
DECLARE f jsonb; s public.direct_order_sessions%ROWTYPE;
BEGIN
 PERFORM set_config('request.jwt.claim.sub','00000000-0000-4000-8000-000000000001',true);
 PERFORM set_config('request.jwt.claims','{"sub":"00000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
 f:=photo_test.create_request(p_photo);
 SELECT session.* INTO s FROM public.direct_order_sessions session
 JOIN public.direct_order_requests r ON r.session_id=session.id WHERE r.id=(f->>'request_id')::uuid;
 RETURN f||jsonb_build_object('session_id',s.id,'secret',s.secret_hash);
END $$;
CREATE FUNCTION proof_test.path(f jsonb) RETURNS text LANGUAGE sql AS $$
 SELECT f->>'store_id'||'/'||(f->>'request_id')||'/'||gen_random_uuid()::text||'.png'
$$;
CREATE FUNCTION proof_test.send(f jsonb, previous uuid, path text DEFAULT NULL, review uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE sql AS $$
 SELECT public.direct_order_public_proof_v3((f->>'session_id')::uuid,f->>'secret',
  (f->>'request_id')::uuid,(f->>'quote_id')::uuid,previous,review,path)
$$;

DO $addresses$
DECLARE
 shop uuid:='d1000000-0000-4000-8000-000000000002'; sid uuid; rid uuid; draft uuid;
 version integer; detail jsonb; address jsonb; payload jsonb; result jsonb; replay jsonb;
 source text; secret text;
BEGIN
 FOR version IN 1..3 LOOP
  FOREACH detail IN ARRAY ARRAY['{}'::jsonb,'{"detail_address":null}'::jsonb,
    '{"detail_address":""}'::jsonb,'{"detail_address":"   "}'::jsonb,
    '{"detail_address":"Floor 2"}'::jsonb] LOOP
   secret:=md5(gen_random_uuid()::text)||md5(gen_random_uuid()::text);
   INSERT INTO public.direct_order_sessions(restaurant_id,secret_hash,locale)
    VALUES(shop,secret,'vi') RETURNING id INTO sid;
   address:=jsonb_build_object('customer_name','Fixture','customer_phone','0901234567',
    'formatted_address','123 Test Street','address_source','manual')||detail;
   payload:=jsonb_build_object('locale','vi','fulfillment_type','delivery','diner_count',1,
    'items',jsonb_build_array(jsonb_build_object('menu_item_id','d1000000-0000-4000-8000-000000000003','quantity',1)),
    'address',address);
   draft:=gen_random_uuid();
   IF version=1 THEN
    result:=public.direct_order_public_submit(sid,secret,draft,payload);
    replay:=public.direct_order_public_submit(sid,secret,draft,payload);
   ELSIF version=2 THEN
    result:=public.direct_order_public_submit_v2(sid,secret,draft,payload);
    replay:=public.direct_order_public_submit_v2(sid,secret,draft,payload);
   ELSE
    result:=public.direct_order_public_submit_v3(sid,secret,draft,payload);
    replay:=public.direct_order_public_submit_v3(sid,secret,draft,payload);
   END IF;
   rid:=(result->>'request_id')::uuid;
   ASSERT (SELECT detail_address=COALESCE(NULLIF(btrim(detail->>'detail_address'),''),'')
    AND latitude IS NULL AND longitude IS NULL AND NOT location_verified
    FROM public.direct_order_request_addresses WHERE request_id=rid),'OPTIONAL_DETAIL_NOT_NORMALIZED';
   ASSERT replay->>'request_id'=result->>'request_id' AND (replay->>'idempotent')::boolean,
    'OPTIONAL_ADDRESS_RETRY_DUPLICATED_ORDER';
  END LOOP;
 END LOOP;
 FOREACH source IN ARRAY ARRAY['pickup','search','map_pin'] LOOP
  secret:=md5(gen_random_uuid()::text)||md5(gen_random_uuid()::text);
  INSERT INTO public.direct_order_sessions(restaurant_id,secret_hash,locale)
   VALUES(shop,secret,'vi') RETURNING id INTO sid;
  address:=jsonb_build_object('customer_name','Fixture','customer_phone','0901234567','address_source',source);
  IF source<>'pickup' THEN
   address:=address||jsonb_build_object('formatted_address','123 Test Street','detail_address','',
    'latitude',10.8,'longitude',106.7,'location_verified',true);
  END IF;
  payload:=jsonb_build_object('locale','vi','fulfillment_type',CASE WHEN source='pickup' THEN 'pickup' ELSE 'delivery' END,
   'diner_count',1,'items',jsonb_build_array(jsonb_build_object('menu_item_id','d1000000-0000-4000-8000-000000000003','quantity',1)),'address',address);
  result:=public.direct_order_public_submit_v3(sid,secret,gen_random_uuid(),payload);
  ASSERT EXISTS(SELECT 1 FROM public.direct_order_request_addresses
   WHERE request_id=(result->>'request_id')::uuid AND
    CASE WHEN source='pickup' THEN detail_address IS NULL AND formatted_address IS NULL ELSE detail_address='' END),
   'PICKUP_OR_LEGACY_LOCATION_REGRESSION';
 END LOOP;
 FOREACH detail IN ARRAY ARRAY['{"formatted_address":"x"}'::jsonb,'{"customer_name":""}'::jsonb,
  '{"customer_phone":"abc"}'::jsonb,jsonb_build_object('detail_address',repeat('x',301))] LOOP
  secret:=md5(gen_random_uuid()::text)||md5(gen_random_uuid()::text);
  INSERT INTO public.direct_order_sessions(restaurant_id,secret_hash,locale)
   VALUES(shop,secret,'vi') RETURNING id INTO sid;
  payload:=jsonb_set(payload,'{fulfillment_type}','"delivery"');
  payload:=jsonb_set(payload,'{address}',jsonb_build_object('customer_name','Fixture','customer_phone','0901234567',
   'formatted_address','123 Test Street','detail_address','','address_source','manual')||detail);
  BEGIN
   PERFORM public.direct_order_public_submit_v3(sid,secret,gen_random_uuid(),payload);
   RAISE EXCEPTION 'INVALID_ADDRESS_ACCEPTED';
  EXCEPTION WHEN raise_exception THEN
   IF SQLERRM<>'DIRECT_ORDER_ADDRESS_INVALID' THEN RAISE; END IF;
  END;
 END LOOP;
 RAISE NOTICE 'OPTIONAL_ADDRESS=PASS v1_v2_v3 missing_null_empty_whitespace detail_max pickup search map_pin retry required_fields';
END;
$addresses$;

DO $proofs$
DECLARE f jsonb; other jsonb; a uuid; b uuid; path text; v jsonb; review jsonb; stock numeric; job jsonb;
BEGIN
 f:=proof_test.scope(); a:=(f->>'proof_id')::uuid; path:=proof_test.path(f);
 v:=proof_test.send(f,a);
 ASSERT v=jsonb_build_object('store_id',f->>'store_id'),'PROOF_AUTHORIZATION_LEAKED_EXTRA_DATA';
 v:=public.direct_order_public_proof_v3((f->>'session_id')::uuid,f->>'secret',
  (f->>'request_id')::uuid,(f->>'quote_id')::uuid,a,NULL,path,true);
 ASSERT v=jsonb_build_object('store_id',f->>'store_id'),'VERIFY_ONLY_COMMITTED_UNVERIFIED_BYTES';
 ASSERT NOT EXISTS(SELECT 1 FROM public.direct_order_messages WHERE attachment_storage_path=path),'VERIFY_ONLY_WROTE_MESSAGE';
 PERFORM photo_test.assert_empty_graph((f->>'request_id')::uuid);
 v:=proof_test.send(f,a,path); b:=(v->>'message_id')::uuid;
 ASSERT NOT (v->>'idempotent')::boolean;
 ASSERT EXISTS(SELECT 1 FROM public.direct_order_messages WHERE id=b
  AND metadata->>'replaces_message_id'=a::text AND metadata->>'quote_id'=f->>'quote_id');
 ASSERT EXISTS(SELECT 1 FROM public.direct_order_messages WHERE id=a),'ORIGINAL_PROOF_REMOVED';
 ASSERT (proof_test.send(f,a,path)->>'idempotent')::boolean,'LOST_COMMIT_NOT_IDEMPOTENT';
 PERFORM photo_test.assert_empty_graph((f->>'request_id')::uuid);
 BEGIN
  PERFORM proof_test.send(f,a,proof_test.path(f));
  RAISE EXCEPTION 'STALE_REPLACEMENT_ACCEPTED';
 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM<>'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED' THEN RAISE; END IF;
 END;
 BEGIN
  PERFORM public.direct_order_record_receipt((f->>'store_id')::uuid,(f->>'request_id')::uuid,
   (f->>'quote_id')::uuid,a,108000,'stale-'||(f->>'request_id'));
  RAISE EXCEPTION 'STALE_APPROVAL_ACCEPTED';
 EXCEPTION WHEN raise_exception THEN
  IF SQLERRM<>'DIRECT_ORDER_PAYMENT_REVIEW_CHANGED' THEN RAISE; END IF;
 END;
 INSERT INTO public.direct_order_request_addresses(request_id,restaurant_id,customer_name,customer_phone,
  formatted_address,detail_address,address_source,location_verified)
 VALUES((f->>'request_id')::uuid,(f->>'store_id')::uuid,'Fixture','0901234567','123 Test Street','','manual',false);
 SELECT current_stock INTO stock FROM public.inventory_items WHERE id='d1000000-0000-4000-8000-000000000004';
 PERFORM public.direct_order_record_receipt((f->>'store_id')::uuid,(f->>'request_id')::uuid,
  (f->>'quote_id')::uuid,b,108000,'proof-'||(f->>'request_id'));
 PERFORM public.direct_order_record_receipt((f->>'store_id')::uuid,(f->>'request_id')::uuid,
  (f->>'quote_id')::uuid,b,108000,'proof-'||(f->>'request_id'));
 ASSERT (SELECT count(*)=1 FROM public.direct_order_payment_receipts WHERE request_id=(f->>'request_id')::uuid);
 ASSERT (SELECT current_stock=stock-10 FROM public.inventory_items WHERE id='d1000000-0000-4000-8000-000000000004'),
  'REPLACEMENT_DUPLICATED_STOCK';
 job:=public.enqueue_direct_delivery_driver_receipt((f->>'store_id')::uuid,(f->>'request_id')::uuid);
 ASSERT EXISTS(SELECT 1 FROM public.print_jobs WHERE id=(job->>'job_id')::uuid
  AND payload->>'detail_address'='' AND payload->>'formatted_address'='123 Test Street'), 'EMPTY_DETAIL_RECEIPT_FAILED';
 BEGIN
  PERFORM proof_test.send(f,b,proof_test.path(f)); RAISE EXCEPTION 'PAID_PROOF_REPLACED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'DIRECT_ORDER_PROOF_NOT_ALLOWED' THEN RAISE; END IF; END;
 ASSERT (proof_test.send(f,a,path)->>'idempotent')::boolean,'APPROVED_REPLAY_NOT_RECOVERABLE';

 f:=proof_test.scope(); a:=(f->>'proof_id')::uuid;
 review:=public.direct_order_staff_request_proof_resubmission((f->>'store_id')::uuid,
  (f->>'request_id')::uuid,a,'wrong_transaction');
 BEGIN
  PERFORM proof_test.send(f,a,proof_test.path(f)); RAISE EXCEPTION 'REVIEW_OWNER_BYPASSED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'DIRECT_ORDER_PROOF_REVIEW_NOT_ALLOWED' THEN RAISE; END IF; END;
 v:=proof_test.send(f,a,proof_test.path(f),(review->>'id')::uuid);
 ASSERT EXISTS(SELECT 1 FROM public.direct_order_proof_review_requests WHERE id=(review->>'id')::uuid
  AND status='resubmitted' AND replacement_message_id=(v->>'message_id')::uuid);
 other:=proof_test.scope();
 BEGIN
  PERFORM proof_test.send(other||jsonb_build_object('session_id',f->>'session_id','secret',f->>'secret'),
   (other->>'proof_id')::uuid,proof_test.path(other)); RAISE EXCEPTION 'OTHER_CUSTOMER_ACCEPTED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'DIRECT_ORDER_REQUEST_NOT_FOUND' THEN RAISE; END IF; END;
 BEGIN
  PERFORM proof_test.send(other,(other->>'proof_id')::uuid,proof_test.path(f)); RAISE EXCEPTION 'OTHER_PATH_ACCEPTED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'DIRECT_ORDER_PROOF_PATH_INVALID' THEN RAISE; END IF; END;
 f:=proof_test.scope(false);
 UPDATE public.direct_order_requests SET state='quoted' WHERE id=(f->>'request_id')::uuid;
 UPDATE public.direct_order_quotes SET status='active',expires_at=now()+interval '1 hour'
  WHERE id=(f->>'quote_id')::uuid;
 v:=proof_test.send(f,NULL,proof_test.path(f));
 ASSERT v->>'state'='awaiting_payment_review';
 ASSERT (SELECT status='locked' FROM public.direct_order_quotes WHERE id=(f->>'quote_id')::uuid);
 RAISE NOTICE 'PROOF_REPLACEMENT=PASS initial replace immutable_history replay stale_photo receipt_once stock_once driver_receipt review customer_path_isolation';
END;
$proofs$;

CREATE TABLE proof_test.races(kind text PRIMARY KEY,scope jsonb);
INSERT INTO proof_test.races SELECT kind,proof_test.scope() FROM unnest(ARRAY['replace','approve_first','replace_first'])kind;
