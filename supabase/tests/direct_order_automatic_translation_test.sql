DO $translation$
DECLARE f jsonb;r uuid;s uuid;m uuid;j jsonb;v jsonb;sid uuid;secret text;results jsonb;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid');r:=(f->>'request_id')::uuid;s:=(f->>'store_id')::uuid;
 UPDATE public.direct_order_requests SET locale='ko',customer_note='양파 빼 주세요' WHERE id=r;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body) VALUES(r,s,'cashier','text','Vui lòng chuyển thêm 10,000 VND') RETURNING id INTO m;
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_translation_jobs WHERE source_id=m AND target_locale='ko') THEN RAISE EXCEPTION 'CASHIER_TARGET_LOCALE_WRONG'; END IF;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body) VALUES(r,s,'customer','text','양파 빼 주세요');
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_translation_jobs WHERE request_id=r AND source_kind='message' AND target_locale='vi') THEN RAISE EXCEPTION 'CUSTOMER_TARGET_LOCALE_WRONG'; END IF;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body) VALUES(r,s,'system','system','DIRECT_ORDER_QUOTE_SENT');
 -- A diverse multibyte maximum-length chat remains a valid enqueue operation.
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body)
 SELECT r,s,'customer','text',string_agg(chr(44032+((i*7919)%11172)),'' ORDER BY i) FROM generate_series(1,2000) i;
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_translation_jobs WHERE request_id=r AND char_length(source_text)=2000) THEN RAISE EXCEPTION 'LONG_CHAT_NOT_ENQUEUED'; END IF;
 j:=public.claim_direct_order_translations(10);
 IF jsonb_array_length(j)<3 THEN RAISE EXCEPTION 'TRANSLATION_JOBS_NOT_CLAIMED %',j; END IF;
 SELECT jsonb_agg(value||jsonb_build_object('translated_text',CASE WHEN value->>'target_locale'='ko' THEN '10,000 VND를 추가 입금해 주세요' ELSE 'Không hành tây' END)) INTO results FROM jsonb_array_elements(j);
 PERFORM public.complete_direct_order_translations(results);
 PERFORM public.complete_direct_order_translations(results);
 IF (SELECT body FROM public.direct_order_messages WHERE id=m)<>'Vui lòng chuyển thêm 10,000 VND' OR (SELECT metadata->'translations'->>'ko' FROM public.direct_order_messages WHERE id=m)<>'10,000 VND를 추가 입금해 주세요' THEN RAISE EXCEPTION 'TRANSLATION_OVERWROTE_ORIGINAL'; END IF;
 v:=public.direct_order_staff_detail_v3(s,r);
 IF v->'request'->'note_translations'->>'vi'<>'Không hành tây' THEN RAISE EXCEPTION 'NOTE_TRANSLATION_NOT_EXPOSED %',v; END IF;
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=r;SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
 v:=public.direct_order_public_status_v7(sid,secret,r);
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v->'messages') e WHERE e->>'id'=m::text AND e->'metadata'->'translations'->>'ko'='10,000 VND를 추가 입금해 주세요') THEN RAISE EXCEPTION 'CUSTOMER_TRANSLATION_MISSING'; END IF;
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(public.direct_order_public_status_v6(sid,secret,r)->'messages') e WHERE e ? 'metadata') THEN RAISE EXCEPTION 'LEGACY_STATUS_TRANSLATION_DRIFT'; END IF;
 IF EXISTS(SELECT 1 FROM public.direct_order_translation_jobs WHERE request_id=r AND source_text='DIRECT_ORDER_QUOTE_SENT') THEN RAISE EXCEPTION 'SYSTEM_TEXT_SENT_TO_GPT'; END IF;
 PERFORM public.direct_delivery_ticket_list_v3(s,NULL,200);
END; $translation$;
SELECT 'DIRECT_ORDER_AUTOMATIC_TRANSLATION=PASS';
-- Synthetic regression: run after money + translation migrations in codex_direct_photo.
BEGIN;
SET LOCAL request.jwt.claim.sub='00000000-0000-4000-8000-000000000001';
DO $legacy_compatibility$
DECLARE row record; v jsonb; f jsonb; rid uuid; sid uuid; secret text; m uuid; new_status jsonb; version integer;
BEGIN
 IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
 IF to_regclass('photo_test.pre_translation_status') IS NOT NULL THEN
  FOR row IN SELECT * FROM photo_test.pre_translation_status LOOP
   IF pg_get_functiondef(row.identity::regprocedure) IS DISTINCT FROM row.definition THEN RAISE EXCEPTION 'LEGACY_STATUS_BODY_CHANGED: %',row.identity; END IF;
   EXECUTE format('SELECT public.direct_order_public_status_v%s($1,$2,$3)',row.version) INTO v USING row.session_id,row.secret_hash,row.request_id;
   IF v IS DISTINCT FROM row.payload THEN RAISE EXCEPTION 'LEGACY_STATUS_PAYLOAD_CHANGED: %',row.version; END IF;
  END LOOP;
 END IF;
 f:=photo_test.create_request(false,'customer_direct');rid:=(f->>'request_id')::uuid;
 SELECT r.session_id,s.secret_hash INTO sid,secret FROM public.direct_order_requests r JOIN public.direct_order_sessions s ON s.id=r.session_id WHERE r.id=rid;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,metadata)
 VALUES(rid,(f->>'store_id')::uuid,'customer','text','Please omit onions.',jsonb_build_object('translations',jsonb_build_object('vi','Không hành tây'),'translation_status','translated')) RETURNING id INTO m;
 FOR version IN 3..6 LOOP
  EXECUTE format('SELECT public.direct_order_public_status_v%s($1,$2,$3)',version) INTO v USING sid,secret,rid;
  IF EXISTS(SELECT 1 FROM jsonb_array_elements(v->'messages') e WHERE e ?| ARRAY['metadata','translations','translation_status']) THEN RAISE EXCEPTION 'LEGACY_STATUS_TRANSLATION_FIELDS: %',version; END IF;
 END LOOP;
 new_status:=public.direct_order_public_status_v7(sid,secret,rid);
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(new_status->'messages') e WHERE e->>'id'=m::text AND e->'metadata'->'translations'->>'vi'='Không hành tây') THEN RAISE EXCEPTION 'V7_TRANSLATION_MISSING'; END IF;
 IF (SELECT provolatile FROM pg_proc WHERE oid='public.direct_order_public_status_v7(uuid,text,uuid)'::regprocedure)<>'v' THEN RAISE EXCEPTION 'V7_STATUS_SESSION_ACTIVITY_NOT_VOLATILE'; END IF;
END; $legacy_compatibility$;
ROLLBACK;
SELECT 'DIRECT_ORDER_V3_V6_COMPATIBILITY_AND_V7_TRANSLATION=PASS';

BEGIN;
SET LOCAL request.jwt.claim.sub='00000000-0000-4000-8000-000000000001';
DO $prior_day_excess$
DECLARE f jsonb; rid uuid; store uuid; quote uuid; proof uuid; evidence uuid; result jsonb; list jsonb; row jsonb; day_start timestamptz;
BEGIN
 IF current_database()<>'codex_direct_photo' THEN RAISE EXCEPTION 'DISPOSABLE_DATABASE_REQUIRED'; END IF;
 f:=photo_test.create_request(true,'store_prepaid');rid:=(f->>'request_id')::uuid;store:=(f->>'store_id')::uuid;quote:=(f->>'quote_id')::uuid;proof:=(f->>'proof_id')::uuid;
 result:=public.direct_order_record_receipt(store,rid,quote,proof,120000,'SKEPTIC-PRIOR-DAY-EXCESS');
 day_start:=(now() AT TIME ZONE 'Asia/Ho_Chi_Minh')::date::timestamp AT TIME ZONE 'Asia/Ho_Chi_Minh';
 -- This transaction rolls back; move competing completed fixture rows behind the target to exercise LIMIT 1.
 UPDATE public.direct_order_requests r SET created_at=day_start-interval '2 days' WHERE r.restaurant_id=store AND r.id<>rid AND EXISTS(SELECT 1 FROM public.direct_delivery_fulfillment_tickets t WHERE t.request_id=r.id AND t.status='completed');
 UPDATE public.direct_order_requests SET created_at=day_start-interval '1 second',delivery_fee_finalized=true WHERE id=rid;
 UPDATE public.direct_delivery_fulfillment_tickets SET status='completed',completed_at=day_start-interval '1 second' WHERE request_id=rid;
 list:=public.direct_order_staff_list_v3(store,ARRAY['customer_completed'],1,'delivery');
 IF jsonb_array_length(list)<>1 OR list->0->>'id'<>rid::text OR (list->0->>'overpayment_due')::numeric<>12000 OR (list->0->>'refund_pending')::boolean IS DISTINCT FROM true THEN RAISE EXCEPTION 'PRIOR_DAY_COMPLETED_EXCESS_MISSING_BEFORE_LIMIT: %',list; END IF;
 IF NOT public.direct_order_access_is_open(rid) THEN RAISE EXCEPTION 'PRIOR_DAY_EXCESS_CUSTOMER_ACCESS_CLOSED'; END IF;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body,attachment_storage_path) VALUES(rid,store,'cashier','attachment','Synthetic prior-day refund evidence',store::text||'/'||rid::text||'/'||gen_random_uuid()::text||'.jpg') RETURNING id INTO evidence;
 result:=public.direct_order_staff_support_action(store,rid,(SELECT support_version FROM public.direct_order_requests WHERE id=rid),'refund_overpayment',jsonb_build_object('operation_id',gen_random_uuid(),'amount',12000,'reference','SKEPTIC-PRIOR-DAY-REFUND','method','BANKTRANSFER','evidence_message_id',evidence));
 IF public.direct_order_overpayment_due(rid)<>0 THEN RAISE EXCEPTION 'PRIOR_DAY_EXCESS_NOT_CLEARED'; END IF;
 list:=public.direct_order_staff_list_v3(store,ARRAY['customer_completed'],200,'delivery');
 IF EXISTS(SELECT 1 FROM jsonb_array_elements(list) e WHERE e->>'id'=rid::text) THEN RAISE EXCEPTION 'PRIOR_DAY_REFUNDED_COMPLETED_ORDER_REMAINS_PENDING'; END IF;
END; $prior_day_excess$;
ROLLBACK;
SELECT 'DIRECT_ORDER_PRIOR_DAY_COMPLETED_EXCESS_LIST=PASS limit_before_refund=1 absent_after_refund=PASS';

BEGIN;
DO $fair_batch$
DECLARE a jsonb;b jsonb;rid uuid;store uuid;jobs jsonb;next_jobs jsonb;
BEGIN
 a:=photo_test.create_request(false,'customer_direct');b:=photo_test.create_request(false,'customer_direct');rid:=(a->>'request_id')::uuid;store:=(a->>'store_id')::uuid;
 -- Isolate this fairness scenario without changing persisted fixture queues.
 UPDATE public.direct_order_translation_jobs SET status='translated' WHERE request_id NOT IN ((a->>'request_id')::uuid,(b->>'request_id')::uuid);
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body)
 SELECT rid,store,'customer','text','Order A message '||i FROM generate_series(1,20) i;
 INSERT INTO public.direct_order_messages(request_id,restaurant_id,sender_type,message_type,body) VALUES((b->>'request_id')::uuid,(b->>'store_id')::uuid,'customer','text','Order B message');
 UPDATE public.direct_order_translation_jobs SET created_at=now()-interval '1 minute' WHERE request_id=rid;
 jobs:=public.claim_direct_order_translations(10);
 IF jsonb_array_length(jobs)<>10 OR (SELECT count(DISTINCT request_id) FROM public.direct_order_translation_jobs WHERE id IN (SELECT (value->>'id')::uuid FROM jsonb_array_elements(jobs)))<>1 THEN RAISE EXCEPTION 'TRANSLATION_BATCH_CROSSES_ORDER'; END IF;
 PERFORM public.complete_direct_order_translations((SELECT jsonb_agg(value||jsonb_build_object('translated_text',NULL)) FROM jsonb_array_elements(jobs)));
 next_jobs:=public.claim_direct_order_translations(10);
 IF jsonb_array_length(next_jobs)<>1 OR NOT EXISTS(SELECT 1 FROM public.direct_order_translation_jobs WHERE id=(next_jobs->0->>'id')::uuid AND request_id=(b->>'request_id')::uuid) THEN RAISE EXCEPTION 'TRANSLATION_CHAT_STARVATION'; END IF;
END; $fair_batch$;
ROLLBACK;
SELECT 'DIRECT_ORDER_TRANSLATION_ORDER_ISOLATION_AND_FAIRNESS=PASS';
