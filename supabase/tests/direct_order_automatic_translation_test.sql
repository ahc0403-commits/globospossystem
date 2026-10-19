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
 j:=public.claim_direct_order_translations(10);
 IF jsonb_array_length(j)<3 THEN RAISE EXCEPTION 'TRANSLATION_JOBS_NOT_CLAIMED %',j; END IF;
 SELECT jsonb_agg(value||jsonb_build_object('translated_text',CASE WHEN value->>'target_locale'='ko' THEN '10,000 VND를 추가 입금해 주세요' ELSE 'Không hành tây' END)) INTO results FROM jsonb_array_elements(j);
 PERFORM public.complete_direct_order_translations(results);
 PERFORM public.complete_direct_order_translations(results);
 IF (SELECT body FROM public.direct_order_messages WHERE id=m)<>'Vui lòng chuyển thêm 10,000 VND' OR (SELECT metadata->'translations'->>'ko' FROM public.direct_order_messages WHERE id=m)<>'10,000 VND를 추가 입금해 주세요' THEN RAISE EXCEPTION 'TRANSLATION_OVERWROTE_ORIGINAL'; END IF;
 v:=public.direct_order_staff_detail_v3(s,r);
 IF v->'request'->'note_translations'->>'vi'<>'Không hành tây' THEN RAISE EXCEPTION 'NOTE_TRANSLATION_NOT_EXPOSED %',v; END IF;
 SELECT session_id INTO sid FROM public.direct_order_requests WHERE id=r;SELECT secret_hash INTO secret FROM public.direct_order_sessions WHERE id=sid;
 v:=public.direct_order_public_status_v3(sid,secret,r);
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(v->'messages') e WHERE e->>'id'=m::text AND e->'metadata'->'translations'->>'ko'='10,000 VND를 추가 입금해 주세요') THEN RAISE EXCEPTION 'CUSTOMER_TRANSLATION_MISSING'; END IF;
 IF EXISTS(SELECT 1 FROM public.direct_order_translation_jobs WHERE request_id=r AND source_text='DIRECT_ORDER_QUOTE_SENT') THEN RAISE EXCEPTION 'SYSTEM_TEXT_SENT_TO_GPT'; END IF;
 PERFORM public.direct_delivery_ticket_list_v3(s,NULL,200);
END; $translation$;
SELECT 'DIRECT_ORDER_AUTOMATIC_TRANSLATION=PASS';
