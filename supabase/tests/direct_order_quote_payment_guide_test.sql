CREATE SCHEMA guide_test;
ALTER TABLE storage.objects ADD COLUMN IF NOT EXISTS metadata jsonb;
CREATE FUNCTION guide_test.request(n integer DEFAULT 1,method text DEFAULT 'delivery') RETURNS uuid LANGUAGE plpgsql AS $$
DECLARE r uuid;sid uuid;shop uuid:='d1000000-0000-4000-8000-000000000002';
BEGIN
 UPDATE public.users SET restaurant_id=shop,role='cashier' WHERE auth_id=auth.uid();
 INSERT INTO public.direct_order_sessions(restaurant_id,secret_hash,locale) VALUES(shop,replace(gen_random_uuid()::text||gen_random_uuid()::text,'-',''),'vi') RETURNING id INTO sid;
 INSERT INTO public.direct_order_requests(restaurant_id,session_id,client_request_id,reference_code,state,locale,fulfillment_method)
 VALUES(shop,sid,gen_random_uuid(),'D'||upper(left(replace(gen_random_uuid()::text,'-',''),8)),'awaiting_quote','vi',method) RETURNING id INTO r;
 WITH menus AS(INSERT INTO public.menu_items(id,restaurant_id,vat_category,name,name_ko,name_vi,name_en,price)
 SELECT gen_random_uuid(),shop,'food','Guide fixture '||g,'안내 품목 '||g,'Món thử '||g,'Guide item '||g,100000 FROM generate_series(1,n) g RETURNING *)
 INSERT INTO public.direct_order_request_items(request_id,restaurant_id,menu_item_id,display_name,name_ko,name_vi,name_en,vat_category,unit_price,quantity)
 SELECT r,shop,id,name,name_ko,name_vi,name_en,vat_category,price,1 FROM menus;
 RETURN r;
END $$;
DO $guide$
DECLARE r uuid;shop uuid:='d1000000-0000-4000-8000-000000000002';q jsonb;v jsonb;doc jsonb;other uuid;op uuid:=gen_random_uuid(); path text;before integer;msg jsonb;
BEGIN
 IF EXISTS(SELECT 1 FROM guide_history_snapshot WHERE quote_hash IS DISTINCT FROM
 md5(COALESCE((SELECT jsonb_agg(to_jsonb(histq) ORDER BY histq.id) FROM public.direct_order_quotes histq),'[]')::text)
 OR financial_hash IS DISTINCT FROM md5(COALESCE((SELECT jsonb_agg(to_jsonb(f) ORDER BY request_id) FROM public.direct_order_financials f),'[]')::text))
 THEN RAISE EXCEPTION 'GUIDE_UPGRADE_CHANGED_FINANCIAL_HISTORY'; END IF;
 r:=guide_test.request();
 IF EXISTS(SELECT 1 FROM public.direct_order_quotes WHERE request_id=r) THEN RAISE EXCEPTION 'FIRST_QUOTE_ALREADY_SEEDED'; END IF;
 v:=public.direct_order_staff_detail_v6(shop,r);
 IF v->'amount_summary'->>'finalized'<>'false' OR (v->'amount_summary'->'amounts'->>'final_total')::numeric<>108000 THEN RAISE EXCEPTION 'PREVIEW_PRICE_WRONG'; END IF;
 q:=public.direct_order_staff_quote_with_payment_mode(shop,r,0,'Test quote','customer_direct');
 IF (q->>'final_total')::numeric<>108000 OR q->>'delivery_payment_mode'<>'customer_direct' THEN RAISE EXCEPTION 'FIRST_QUOTE_WRONG'; END IF;
 IF public.direct_order_staff_quote_with_payment_mode(shop,r,0,'Retry','customer_direct')->>'id'<>q->>'id'
 OR (SELECT count(*) FROM public.direct_order_quotes WHERE request_id=r)<>1 OR (SELECT count(*) FROM public.direct_order_messages WHERE request_id=r AND message_type='quote')<>1
 THEN RAISE EXCEPTION 'QUOTE_RETRY_DUPLICATED'; END IF;
 doc:=public.direct_order_staff_payment_document(shop,r,(q->>'id')::uuid,1);
 IF doc->'data'->'bank'->>'bin'<>'970457' OR (doc->'data'->>'amount_due')::numeric<>108000 THEN RAISE EXCEPTION 'GUIDE_BANK_OR_AMOUNT_WRONG'; END IF;
 IF public.direct_order_staff_payment_document(shop,r,(q->>'id')::uuid,1,false)->'data'->'bank'<>'null'::jsonb THEN RAISE EXCEPTION 'QUOTE_LEAKED_BANK'; END IF;
 SELECT count(*) INTO before FROM public.payments;
 v:=public.direct_order_staff_issue_order_link(shop,r,op,repeat('g',43),'https://globospossystem.vercel.app',false);
 v:=public.direct_order_staff_issue_order_link(shop,r,op,repeat('g',43),'https://globospossystem.vercel.app',true);
 IF public.direct_order_staff_issue_order_link(shop,r,op,repeat('g',43),'https://globospossystem.vercel.app',true)<>v
 OR (SELECT count(*) FROM public.direct_order_messages WHERE request_id=r AND metadata->>'order_access_link'='true')<>1 THEN RAISE EXCEPTION 'LINK_RETRY_DUPLICATED'; END IF;
 IF EXISTS(SELECT 1 FROM public.direct_order_translation_jobs WHERE source_id=(v->>'message_id')::uuid) THEN RAISE EXCEPTION 'ORDER_KEY_SENT_TO_TRANSLATION'; END IF;
 PERFORM public.direct_order_resolve_access(r,encode(extensions.digest(convert_to(repeat('g',43),'UTF8'),'sha256'),'hex'));
 other:=guide_test.request();
 BEGIN PERFORM public.direct_order_resolve_access(other,encode(extensions.digest(convert_to(repeat('g',43),'UTF8'),'sha256'),'hex')); RAISE EXCEPTION 'LINK_OTHER_ORDER_ACCESS';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_UNAVAILABLE' THEN RAISE; END IF; END;
 path:=shop::text||'/'||r::text||'/'||gen_random_uuid()::text||'.pdf';
 BEGIN PERFORM public.direct_order_staff_commit_payment_document(shop,r,(q->>'id')::uuid,1,true,doc->>'source_hash',path,'guide.pdf','application/pdf'); RAISE EXCEPTION 'MISSING_FILE_COMMITTED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'PROOF_UPLOAD_INCOMPLETE' THEN RAISE; END IF; END;
 INSERT INTO storage.objects(bucket_id,name,metadata) VALUES('direct-order-chat',path,'{"size":1234}');
 msg:=public.direct_order_staff_commit_payment_document(shop,r,(q->>'id')::uuid,1,true,doc->>'source_hash',path,'guide.pdf','application/pdf');
 IF public.direct_order_staff_commit_payment_document(shop,r,(q->>'id')::uuid,1,true,doc->>'source_hash',path,'guide.pdf','application/pdf')<>msg
 OR EXISTS(SELECT 1 FROM public.direct_order_messages WHERE request_id=r AND message_type='payment_proof') OR (SELECT count(*) FROM public.payments)<>before THEN RAISE EXCEPTION 'GUIDE_CREATED_PAYMENT_OR_DUPLICATE'; END IF;
 BEGIN PERFORM public.direct_order_staff_payment_document(shop,r,(q->>'id')::uuid,2); RAISE EXCEPTION 'STALE_GUIDE_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_QUOTE_CHANGED' THEN RAISE; END IF; END;
 BEGIN PERFORM public.direct_order_staff_payment_document('d2000000-0000-4000-8000-000000000001',r,(q->>'id')::uuid,1); RAISE EXCEPTION 'OTHER_STORE_GUIDE_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM NOT IN('DIRECT_ORDER_FORBIDDEN','DIRECT_ORDER_REQUEST_NOT_FOUND') THEN RAISE; END IF; END;
 UPDATE public.direct_order_requests SET state='rejected' WHERE id=r;
 BEGIN PERFORM public.direct_order_staff_payment_document(shop,r,(q->>'id')::uuid,1); RAISE EXCEPTION 'REJECTED_GUIDE_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_PAYMENT_DOCUMENT_NOT_ALLOWED' THEN RAISE; END IF; END;
 IF public.direct_order_staff_commit_payment_document(shop,r,(q->>'id')::uuid,1,true,doc->>'source_hash',path,'guide.pdf','application/pdf')<>msg THEN RAISE EXCEPTION 'COMMITTED_GUIDE_RETRY_LOST'; END IF;
 BEGIN PERFORM public.direct_order_staff_issue_order_link(shop,r,gen_random_uuid(),repeat('h',43),'https://globospossystem.vercel.app',true); RAISE EXCEPTION 'REJECTED_LINK_ALLOWED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_ORDER_CLOSED' THEN RAISE; END IF; END;
 r:=guide_test.request(1,'pickup');PERFORM public.direct_order_staff_quote_with_payment_mode(shop,r,0,NULL,'customer_direct');
 RAISE NOTICE 'PASS: actual first delivery/pickup quotes, preview, exact retry, scoped links, guide/commit state and payment isolation';
END $guide$;
