BEGIN;
INSERT INTO public.table_qr_tokens VALUES
 ('jgb','273b057e-3b69-46e3-93c1-6194c2802849','10000000-0000-4000-8000-000000000001',true),
 ('other','90000000-0000-4000-8000-000000000001','10000000-0000-4000-8000-000000000002',true),
 ('disabled','273b057e-3b69-46e3-93c1-6194c2802849','10000000-0000-4000-8000-000000000001',false);
INSERT INTO public.orders
SELECT ('20000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 CASE WHEN n=1 THEN '273b057e-3b69-46e3-93c1-6194c2802849'::uuid ELSE '90000000-0000-4000-8000-000000000001'::uuid END,
 ('10000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,'serving','2026-10-21 01:00Z','2026-10-21 01:00Z'
FROM generate_series(1,2) n;
INSERT INTO public.order_items
SELECT gen_random_uuid(),o.id,o.restaurant_id,'served','menu_item',false,
 '2026-10-21 01:00Z'::timestamptz+n*interval '1 minute',
 CASE WHEN n=1 THEN 'Original food' ELSE 'Additional cola' END,1
FROM public.orders o CROSS JOIN generate_series(1,2) n;
INSERT INTO public.qr_order_display_states
SELECT id,'2026-10-21 01:02Z',1,'2026-10-21 01:02Z','2026-10-21 01:02Z' FROM public.orders;
DO $$ DECLARE result jsonb; before_rows text; started_at timestamptz;
BEGIN
 SELECT md5(jsonb_agg(to_jsonb(i) ORDER BY id)::text) INTO before_rows FROM public.order_items i;
 result:=public.qr_get_active_order_pre_start_ready('jgb');
 ASSERT jsonb_array_length(result->'items')=2,result::text;
 ASSERT result->'items'->0->>'name'='Original food';
 ASSERT result->'items'->1->>'name'='Additional cola';
 ASSERT result->>'display_version'='1' AND result->>'display_reset_at' IS NOT NULL;
 result:=public.qr_get_active_order_pre_start_ready('other');
 ASSERT jsonb_array_length(result->'items')=1,result::text;
 ASSERT result->'items'->0->>'name'='Additional cola';
 BEGIN
  PERFORM public.qr_get_active_order_pre_start_ready('disabled');
  RAISE EXCEPTION 'DISABLED_TOKEN_ACCEPTED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='QR_TOKEN_INVALID',SQLERRM; END;
 ASSERT before_rows=(SELECT md5(jsonb_agg(to_jsonb(i) ORDER BY id)::text) FROM public.order_items i);
 UPDATE public.orders SET status='completed' WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849';
 result:=public.qr_get_active_order_pre_start_ready('jgb');
 ASSERT result->>'active'='false' AND jsonb_array_length(result->'items')=0;
 ASSERT result->>'last_closed_order_id'='20000000-0000-4000-8000-000000000001';
 INSERT INTO public.orders VALUES('20000000-0000-4000-8000-000000000003',
  '273b057e-3b69-46e3-93c1-6194c2802849','10000000-0000-4000-8000-000000000001',
  'pending','2026-10-21 02:00Z','2026-10-21 02:00Z');
 INSERT INTO public.qr_order_display_states VALUES('20000000-0000-4000-8000-000000000003','2026-10-21 02:30Z',1,'2026-10-21 02:30Z','2026-10-21 02:30Z');
 INSERT INTO public.order_items
 SELECT gen_random_uuid(),'20000000-0000-4000-8000-000000000003','273b057e-3b69-46e3-93c1-6194c2802849',
  'served','menu_item',false,'2026-10-21 02:00Z'::timestamptz+n*interval '1 second','New party '||n,1
 FROM generate_series(1,200) n;
 started_at:=clock_timestamp();
 result:=public.qr_get_active_order_pre_start_ready('jgb');
 ASSERT result->>'order_id'='20000000-0000-4000-8000-000000000003';
 ASSERT jsonb_array_length(result->'items')=200;
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(result->'items') i WHERE i->>'name' IN ('Original food','Additional cola'));
 RAISE NOTICE 'QR_ACTIVE_HISTORY_200=PASS rpc_calls=1 rows=200 response_bytes=% elapsed_ms=%',
  octet_length(result::text),round(extract(epoch from clock_timestamp()-started_at)*1000,3);
END $$;
ROLLBACK;
SELECT 'JEONGABOK_QR_FULL_ACTIVE_HISTORY=PASS';
