CREATE TABLE guide_history_snapshot AS SELECT
 md5(COALESCE((SELECT jsonb_agg(to_jsonb(q) ORDER BY id) FROM public.direct_order_quotes q),'[]')::text) quote_hash,
 md5(COALESCE((SELECT jsonb_agg(to_jsonb(f) ORDER BY request_id) FROM public.direct_order_financials f),'[]')::text) financial_hash;
BEGIN;
DO $$ DECLARE r uuid; sid uuid; shop uuid:='d1000000-0000-4000-8000-000000000002'; BEGIN
 UPDATE public.users SET restaurant_id=shop WHERE auth_id=auth.uid();
 INSERT INTO public.direct_order_sessions(restaurant_id,secret_hash,locale) VALUES(shop,repeat('f',64),'vi') RETURNING id INTO sid;
 INSERT INTO public.direct_order_requests(restaurant_id,session_id,client_request_id,reference_code,state,locale)
 VALUES(shop,sid,gen_random_uuid(),'DBEFORE01','awaiting_quote','vi') RETURNING id INTO r;
 INSERT INTO public.direct_order_request_items(request_id,restaurant_id,menu_item_id,display_name,name_ko,name_vi,name_en,vat_category,unit_price,quantity)
 VALUES(r,shop,'d1000000-0000-4000-8000-000000000003','Quote creation','안내','Báo giá','Quote','food',100000,1);
 BEGIN
  PERFORM public.direct_order_staff_quote_with_payment_mode(shop,r,0,NULL,'customer_direct');
  RAISE EXCEPTION 'FIRST_QUOTE_FAILURE_NOT_REPRODUCED';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'DIRECT_ORDER_RECIPIENT_PAYMENT_REQUIRED' THEN RAISE; END IF; END;
 IF EXISTS(SELECT 1 FROM public.direct_order_quotes WHERE request_id=r) THEN RAISE EXCEPTION 'FAILED_QUOTE_PARTIALLY_COMMITTED'; END IF;
 RAISE NOTICE 'PASS: actual first quote RPC reproduces recipient policy conflict';
END $$;
ROLLBACK;
