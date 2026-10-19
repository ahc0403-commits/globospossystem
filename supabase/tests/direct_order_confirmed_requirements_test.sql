DO $requirements$
DECLARE f jsonb; other jsonb; r uuid; shop uuid; sid uuid; secret text; q uuid; item_q uuid; mid uuid; mutation uuid;
 v jsonb; original jsonb; digital jsonb; o uuid; receipt_id uuid; token text:=repeat('a',32); count_before integer; memo public.print_jobs%ROWTYPE; reprinted public.print_jobs%ROWTYPE;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid');r:=(f->>'request_id')::uuid;shop:=(f->>'store_id')::uuid;
 UPDATE public.users SET restaurant_id=shop WHERE auth_id=auth.uid();
 UPDATE public.direct_order_requests SET locale='ko',customer_note='도착 전에 전화해주세요' WHERE id=r;
 UPDATE public.direct_order_request_items SET item_note='덜 맵게 해주세요' WHERE request_id=r;
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=r;
 SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
 SELECT id INTO q FROM public.direct_order_customer_requirements WHERE request_id=r AND source_kind='order';
 SELECT id INTO item_q FROM public.direct_order_customer_requirements WHERE request_id=r AND source_kind='item';
 v:=public.direct_order_public_status_v5(sid,secret,r);
 IF jsonb_array_length(v->'requirements')<>2 THEN RAISE EXCEPTION 'REQUEST_SOURCES_NOT_CAPTURED'; END IF;
 IF public.direct_order_public_status_v4(sid,secret,r) ? 'requirements' THEN RAISE EXCEPTION 'LEGACY_STATUS_KEYS_CHANGED'; END IF;
 PERFORM public.direct_order_staff_message(shop,r,'Xin chào');
 IF EXISTS(SELECT 1 FROM public.direct_order_customer_requirements WHERE request_id=r AND status<>'awaiting_reply') THEN RAISE EXCEPTION 'GENERAL_CHAT_RESOLVED_REQUEST'; END IF;
 BEGIN
  PERFORM public.direct_order_staff_quote(shop,r,0,NULL); RAISE EXCEPTION 'PENDING_REQUEST_QUOTE_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_REQUIREMENTS_PENDING' THEN RAISE; END IF; END;
 BEGIN
  PERFORM public.direct_order_staff_reply_requirement(shop,r,q,1,gen_random_uuid(),'','ko',true,'Gọi trước khi đến','Sẽ gọi trước khi đến','delivery'); RAISE EXCEPTION 'EMPTY_REPLY_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_REQUIREMENT_REPLY_INVALID' THEN RAISE; END IF; END;
 BEGIN
  PERFORM public.direct_order_staff_reply_requirement(shop,r,q,1,gen_random_uuid(),'답변','ko',true,'전화','Sẽ gọi','delivery'); RAISE EXCEPTION 'UNPRINTABLE_AGREEMENT_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_REQUIREMENT_REPLY_INVALID' THEN RAISE; END IF; END;
 mutation:=gen_random_uuid();
 v:=public.direct_order_staff_reply_requirement(shop,r,q,1,mutation,'기사에게 도착 전 전화 요청을 전달하겠습니다.','ko',true,'Gọi trước khi đến','Sẽ yêu cầu tài xế gọi trước khi đến','delivery');
 SELECT reply_message_id INTO mid FROM public.direct_order_customer_requirements WHERE id=q;
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_customer_requirements WHERE id=q AND status='awaiting_customer' AND version=2 AND confirmed_at IS NULL) THEN RAISE EXCEPTION 'REPLY_AUTOCONFIRMED'; END IF;
 PERFORM public.direct_order_staff_reply_requirement(shop,r,q,1,mutation,'기사에게 도착 전 전화 요청을 전달하겠습니다.','ko',true,'Gọi trước khi đến','Sẽ yêu cầu tài xế gọi trước khi đến','delivery');
 IF (SELECT count(*) FROM public.direct_order_messages WHERE request_id=r AND metadata->>'requirement_mutation_id'=mutation::text)<>1 THEN RAISE EXCEPTION 'REPLY_RETRY_DUPLICATED'; END IF;
 BEGIN
  PERFORM public.direct_order_staff_reply_requirement(shop,r,q,1,mutation,'다른 답변','ko',true,'Gọi trước khi đến','Sẽ yêu cầu tài xế gọi trước khi đến','delivery'); RAISE EXCEPTION 'MUTATION_REPLAY_CHANGED_BODY';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_REQUIREMENT_VERSION_CONFLICT' THEN RAISE; END IF; END;
 BEGIN
  PERFORM public.direct_order_public_decide_requirement(sid,secret,r,q,1,mid,true); RAISE EXCEPTION 'STALE_CONFIRM_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_REQUIREMENT_VERSION_CONFLICT' THEN RAISE; END IF; END;
 other:=photo_test.create_request(true,'store_prepaid');
 BEGIN
  PERFORM public.direct_order_public_decide_requirement(sid,secret,(other->>'request_id')::uuid,q,2,mid,true); RAISE EXCEPTION 'CROSS_ORDER_CONFIRM_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_REQUEST_NOT_FOUND' THEN RAISE; END IF; END;
 PERFORM public.direct_order_public_decide_requirement(sid,secret,r,q,2,mid,true);
 PERFORM public.direct_order_public_decide_requirement(sid,secret,r,q,2,mid,true);
 IF (SELECT count(*) FROM public.direct_order_messages WHERE request_id=r AND metadata->>'requirement_accepted'='true')<>1 THEN RAISE EXCEPTION 'CONFIRM_RETRY_DUPLICATED'; END IF;
 -- An additional freeform customer reply reopens only the linked request.
 PERFORM public.direct_order_staff_reply_requirement(shop,r,item_q,1,gen_random_uuid(),'소스를 줄이겠습니다. 기본 소스에도 매운맛이 있습니다.','ko',true,'Ít cay','Giảm sốt, sốt gốc vẫn hơi cay','preparation');
 SELECT reply_message_id INTO mid FROM public.direct_order_customer_requirements WHERE id=item_q;
 PERFORM public.direct_order_public_decide_requirement(sid,secret,r,item_q,2,mid,false,'그러면 소스를 별도로 주세요');
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_customer_requirements WHERE id=item_q AND status='awaiting_reply' AND version=3 AND followup_text='그러면 소스를 별도로 주세요') THEN RAISE EXCEPTION 'FOLLOWUP_LOST'; END IF;
 PERFORM public.direct_order_staff_reply_requirement(shop,r,item_q,3,gen_random_uuid(),'소스를 별도로 담아드리겠습니다.','ko',false,'Ít cay, sốt riêng','Để sốt riêng','preparation');
 PERFORM public.direct_order_staff_quote_with_payment_mode(shop,r,0,NULL,'store_prepaid');
 PERFORM photo_test.approve(f);
 SELECT order_id INTO o FROM public.direct_order_financials WHERE request_id=r;
 SELECT payload INTO original FROM public.print_jobs WHERE order_id=o AND copy_type='receipt' LIMIT 1;
 IF original->>'order_notes' NOT LIKE '%Để sốt riêng%' OR original->>'order_notes' NOT LIKE '%Sẽ yêu cầu tài xế gọi%' THEN RAISE EXCEPTION 'AGREEMENT_MISSING_ON_RECEIPT %',original; END IF;
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(original->'confirmed_requirements') c WHERE c.value->>'customer_context_text'='그러면 소스를 별도로 주세요') THEN RAISE EXCEPTION 'CONFIRMED_CUSTOMER_FOLLOWUP_AUDIT_LOST'; END IF;
 IF jsonb_array_length(original->'confirmed_requirements')<>2 THEN RAISE EXCEPTION 'RECEIPT_SOURCE_AGREEMENT_AUDIT_LOST'; END IF;
 INSERT INTO public.digital_receipts(restaurant_id,order_id,snapshot) VALUES(shop,o,jsonb_build_object('order_id',o,'items','[]'::jsonb)) RETURNING id,snapshot INTO receipt_id,digital;
 INSERT INTO public.digital_receipt_links(digital_receipt_id,token_hash,expires_at) VALUES(receipt_id,extensions.digest(token,'sha256'),now()+interval '1 day');
 IF public.get_public_receipt('invalid') IS NOT NULL THEN RAISE EXCEPTION 'INVALID_RECEIPT_TOKEN_ALLOWED'; END IF;
 -- Give kitchen and driver copies different destinations to verify routing.
 INSERT INTO public.printer_destinations(restaurant_id,purpose) VALUES(shop,'kitchen');
 INSERT INTO public.print_jobs(restaurant_id,order_id,copy_type,batch_no,destination_id,payload)
 SELECT shop,o,'kitchen',1,id,jsonb_build_object('ticket','kitchen','items','[]'::jsonb) FROM public.printer_destinations WHERE restaurant_id=shop AND purpose='kitchen' LIMIT 1;
 IF EXISTS(SELECT 1 FROM public.print_jobs WHERE order_id=o AND copy_type='kitchen' AND payload->>'order_notes' LIKE '%tài xế%') THEN RAISE EXCEPTION 'DRIVER_REQUEST_SENT_TO_KITCHEN'; END IF;
 SELECT count(*) INTO count_before FROM public.payments WHERE order_id=o;
 PERFORM public.direct_order_staff_reply_requirement(shop,r,item_q,4,gen_random_uuid(),'소스를 두 개로 나누어 별도 포장하겠습니다.','ko',false,'Sốt riêng','Chia sốt thành hai hộp riêng','preparation');
 IF NOT EXISTS(SELECT 1 FROM public.print_jobs WHERE order_id=o AND copy_type='receipt' AND payload=original) THEN RAISE EXCEPTION 'ORIGINAL_PRINT_MUTATED'; END IF;
 IF (SELECT snapshot FROM public.digital_receipts WHERE id=receipt_id) IS DISTINCT FROM digital THEN RAISE EXCEPTION 'ORIGINAL_DIGITAL_MUTATED'; END IF;
 IF (SELECT count(*) FROM public.payments WHERE order_id=o)<>count_before THEN RAISE EXCEPTION 'ADDENDUM_CREATED_PAYMENT'; END IF;
 IF (SELECT count(*) FROM public.direct_order_requirement_addenda WHERE requirement_id=item_q)<>1 OR (SELECT count(*) FROM public.print_jobs WHERE order_id=o AND copy_type='request_update')<>2 THEN RAISE EXCEPTION 'ADDENDUM_ROUTE_INVALID'; END IF;
 IF EXISTS(SELECT 1 FROM public.print_jobs WHERE order_id=o AND copy_type='request_update' AND (payload ? 'total_amount' OR payload ? 'customer_phone')) THEN RAISE EXCEPTION 'MEMO_CONTAINS_PAYMENT_OR_PII'; END IF;
 SELECT j.* INTO memo FROM public.print_jobs j JOIN public.printer_destinations d ON d.id=j.destination_id WHERE j.order_id=o AND j.copy_type='request_update' AND d.purpose='receipt' LIMIT 1;
 UPDATE public.users SET role='admin' WHERE auth_id=auth.uid();
 reprinted:=public.reprint_print_job(memo.id);
 IF reprinted.destination_id IS DISTINCT FROM memo.destination_id OR reprinted.payload->>'ticket'<>'request_update' THEN RAISE EXCEPTION 'MEMO_REPRINT_ROUTED_TO_WRONG_PRINTER'; END IF;
 UPDATE public.users SET role='cashier' WHERE auth_id=auth.uid();
 v:=public.get_public_receipt(token);
 IF jsonb_array_length(v->'request_addenda')<>1 OR v->'request_addenda'->0->>'order_notes' NOT LIKE '%hai hộp%' THEN RAISE EXCEPTION 'PUBLIC_RECEIPT_ADDENDUM_LOST'; END IF;
 UPDATE public.digital_receipt_links SET revoked_at=now() WHERE digital_receipt_id=receipt_id;
 IF public.get_public_receipt(token) IS NOT NULL THEN RAISE EXCEPTION 'REVOKED_RECEIPT_LEAKED_ADDENDUM'; END IF;
 -- Source edits invalidate the old version; PII purge clears the new stores.
 UPDATE public.direct_order_requests SET customer_note='전화하지 말아주세요' WHERE id=r;
 IF NOT EXISTS(SELECT 1 FROM public.direct_order_customer_requirements WHERE id=q AND status='awaiting_reply' AND reply_message_id IS NULL AND version=3) THEN RAISE EXCEPTION 'CHANGED_SOURCE_NOT_REOPENED'; END IF;
 UPDATE public.direct_order_requests SET pii_purged_at=now(),customer_note=NULL WHERE id=r;
 IF EXISTS(SELECT 1 FROM public.direct_order_customer_requirements WHERE request_id=r) OR EXISTS(SELECT 1 FROM public.direct_order_requirement_addenda WHERE request_id=r) THEN RAISE EXCEPTION 'REQUIREMENT_PII_RETAINED'; END IF;
 IF EXISTS(SELECT 1 FROM public.print_jobs WHERE order_id=o AND copy_type='request_update' AND payload ? 'order_notes') THEN RAISE EXCEPTION 'MEMO_PII_RETAINED'; END IF;
END; $requirements$;

CREATE SCHEMA requirement_measurement;
CREATE TABLE requirement_measurement.scopes(size integer,request_id uuid,restaurant_id uuid,session_id uuid,secret_hash text);
DO $measurement$
DECLARE n integer; f jsonb; r uuid; shop uuid; sid uuid; secret text; v jsonb; plan jsonb; statement text;
BEGIN
 FOREACH n IN ARRAY ARRAY[1,10,50] LOOP
  f:=photo_test.create_request(true,'store_prepaid');r:=(f->>'request_id')::uuid;shop:=(f->>'store_id')::uuid;
  SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=r;
  SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
  -- Seed an exact-size read workload; mutation/source capture is tested above.
  INSERT INTO public.direct_order_customer_requirements(request_id,restaurant_id,source_kind,source_id,request_text,source_locale)
   SELECT r,shop,'item',gen_random_uuid(),'Yêu cầu '||g,'vi' FROM generate_series(1,n) g;
  v:=public.direct_order_staff_detail_v4(shop,r);
  IF jsonb_array_length(v->'requirements')<>n THEN RAISE EXCEPTION 'MEASURED_REQUEST_COUNT_INVALID'; END IF;
  v:=public.direct_order_staff_list_v4(shop,NULL,200);
  IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v) e WHERE e.value->>'id'=r::text AND (e.value->>'request_reply_due')::integer=n) THEN RAISE EXCEPTION 'BATCH_PENDING_COUNT_INVALID'; END IF;
  SELECT prosrc INTO statement FROM pg_proc WHERE oid='public.direct_order_requirement_snapshot(uuid)'::regprocedure;
  EXECUTE 'EXPLAIN (ANALYZE,FORMAT JSON) '||statement INTO plan USING r;
  IF plan::text LIKE '%SubPlan%' THEN RAISE EXCEPTION 'REQUEST_SNAPSHOT_CORRELATED_SUBPLAN'; END IF;
  INSERT INTO requirement_measurement.scopes VALUES(n,r,shop,sid,secret);
 END LOOP;
END; $measurement$;
CREATE TABLE requirement_measurement.concurrent_decision(session_id uuid,secret_hash text,request_id uuid,requirement_id uuid,version integer,reply_message_id uuid);
DO $race_scope$
DECLARE f jsonb; r uuid; shop uuid; q uuid; sid uuid; secret text;
BEGIN
 f:=photo_test.create_request(true,'store_prepaid');r:=(f->>'request_id')::uuid;shop:=(f->>'store_id')::uuid;
 UPDATE public.direct_order_requests SET customer_note='Để sốt riêng' WHERE id=r;
 SELECT id INTO q FROM public.direct_order_customer_requirements WHERE request_id=r;
 PERFORM public.direct_order_staff_reply_requirement(shop,r,q,1,gen_random_uuid(),'Sẽ để sốt riêng','vi',true,'Để sốt riêng','Sẽ để sốt riêng','preparation');
 INSERT INTO requirement_measurement.concurrent_decision SELECT r.session_id,s.secret_hash,r.id,q.id,q.version,q.reply_message_id FROM public.direct_order_requests r JOIN public.direct_order_sessions s ON s.id=r.session_id JOIN public.direct_order_customer_requirements q ON q.request_id=r.id WHERE r.id=(f->>'request_id')::uuid;
END; $race_scope$;
SELECT 'DIRECT_ORDER_CONFIRMED_REQUIREMENTS=PASS';
