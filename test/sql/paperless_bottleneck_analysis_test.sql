BEGIN;
SELECT set_config('request.jwt.claim.sub','b1000000-0000-4000-8000-0000000000a1',true);
ALTER TABLE public.emergency_order_queue ADD COLUMN IF NOT EXISTS kitchen_direct_to_floor boolean DEFAULT false;
CREATE TEMP TABLE bottleneck_rows AS SELECT n,
 md5('bottleneck-order-'||n)::uuid AS order_id,
 md5('bottleneck-line-'||n)::uuid AS line_id,
 md5('bottleneck-item-'||n)::uuid AS item_id,
 md5('bottleneck-queue-'||n)::uuid AS queue_id,
 md5('bottleneck-menu')::uuid AS menu_id,
 n>20 AS current_period,
 timestamptz '2026-10-09 12:00Z'+CASE WHEN n>20 THEN interval '1 day' ELSE interval '0' END AS received_at,
 CASE WHEN n>20 THEN 600 ELSE 480 END AS kitchen,
 120 AS handoff, CASE WHEN n>20 THEN 60 ELSE 120 END AS floor
FROM generate_series(1,40) n;
INSERT INTO public.menu_items(id,restaurant_id,name,name_ko,price)
SELECT DISTINCT menu_id,'8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,'Synthetic','검증 메뉴',10000 FROM bottleneck_rows;
INSERT INTO public.orders(id,restaurant_id,status)
SELECT order_id,'8bc9eef5-dcd5-46b1-b931-23f77132322c','completed' FROM bottleneck_rows;
INSERT INTO public.order_items(id,restaurant_id,order_id,menu_item_id,menu_item_id_snapshot,label,quantity,unit_price,status,created_at)
SELECT line_id,'8bc9eef5-dcd5-46b1-b931-23f77132322c',order_id,menu_id,menu_id,'검증 메뉴',1,10000,'served',received_at FROM bottleneck_rows;
INSERT INTO public.emergency_order_queue(id,session_id,order_id,restaurant_id,created_at)
SELECT queue_id,'00000000-0000-4000-8000-000000000031',order_id,'8bc9eef5-dcd5-46b1-b931-23f77132322c',received_at FROM bottleneck_rows;
INSERT INTO public.emergency_fulfillment_items(id,restaurant_id,session_id,order_id,order_item_id,ordered_quantity,kitchen_done_quantity,tray_dispatched_quantity,floor_served_quantity,is_cancelled)
SELECT item_id,'8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000031',order_id,line_id,1,1,1,1,false FROM bottleneck_rows;
INSERT INTO public.emergency_fulfillment_events(session_id,order_id,restaurant_id,order_item_id,stage,delta,created_at)
SELECT '00000000-0000-4000-8000-000000000031',order_id,'8bc9eef5-dcd5-46b1-b931-23f77132322c',line_id,
 stage,1,received_at+seconds*interval '1 second'
FROM bottleneck_rows CROSS JOIN LATERAL(VALUES('kitchen_done',kitchen),('tray_dispatched',kitchen+handoff),('floor_served',kitchen+handoff+floor)) event(stage,seconds);
DO $test$
DECLARE result jsonb; metric jsonb; menu_key text:=md5('bottleneck-menu')::uuid::text;
BEGIN
 result:=public.get_paperless_bottleneck_analysis('8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-10-09 17:00Z','2026-10-10 17:00Z','kitchen',19,menu_key);
 SELECT value INTO metric FROM jsonb_array_elements(result->'stages') value WHERE value->>'stage'='kitchen';
 IF metric->>'current_mean'<>'600' OR metric->>'baseline_mean'<>'480'
  OR metric->>'current_p90'<>'600' OR metric->>'baseline_p90'<>'480'
  OR metric->>'current_count'<>'20' OR result->>'baseline_from'<>'2026-10-09'
  OR result->'menus'->0->>'extra_seconds'<>'2400'
  OR result->>'sample_count'<>'20' OR jsonb_array_length(result->'samples')<>20
  OR result->'samples'->0->>'received_at'<>'2026-10-10T12:00:00+00:00' THEN
  RAISE EXCEPTION 'Stage/hour/menu/timeline mismatch: %',result;
 END IF;
 result:=public.get_paperless_bottleneck_analysis('8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-10-09 17:00Z','2026-10-10 17:00Z','kitchen',18,NULL);
 IF result->'menus'<>'[]'::jsonb OR result->'samples'<>'[]'::jsonb THEN RAISE EXCEPTION 'Hour slice leaked'; END IF;
 BEGIN
  PERFORM public.get_paperless_bottleneck_analysis('b1000000-0000-4000-8000-000000000005','2026-10-09','2026-10-10');
  RAISE EXCEPTION 'Cross-store accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'ADMIN_MUTATION_FORBIDDEN' THEN RAISE; END IF; END;
 BEGIN
  PERFORM public.get_paperless_bottleneck_analysis('8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-10-09','2026-10-10','floor',24);
  RAISE EXCEPTION 'Bad hour accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'PAPERLESS_REPORT_RANGE_INVALID' THEN RAISE; END IF; END;
END;$test$;
-- Compatibility tray timestamps are not checker work in a direct workflow.
UPDATE public.emergency_order_queue SET kitchen_direct_to_floor=true WHERE id IN(SELECT queue_id FROM bottleneck_rows WHERE current_period);
DO $test$
DECLARE result jsonb; metric jsonb;
BEGIN
 result:=public.get_paperless_bottleneck_analysis('8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-10-09 17:00Z','2026-10-10 17:00Z','floor',19,md5('bottleneck-menu')::uuid::text);
 SELECT value INTO metric FROM jsonb_array_elements(result->'stages') value WHERE value->>'stage'='handoff';
 IF metric->>'current_count'<>'0' OR metric->'current_mean'<>'null'::jsonb THEN RAISE EXCEPTION 'Invented checker stage: %',metric; END IF;
 SELECT value INTO metric FROM jsonb_array_elements(result->'stages') value WHERE value->>'stage'='floor';
 IF metric->>'current_mean'<>'180' OR result->'samples'->0->'handoff_at'<>'null'::jsonb OR result->>'direct_to_floor_count'<>'20' THEN
  RAISE EXCEPTION 'Direct floor must start at actual kitchen completion: %',result; END IF;
END;$test$;
DELETE FROM public.emergency_fulfillment_events WHERE order_item_id IN(SELECT line_id FROM bottleneck_rows WHERE n IN(39,40));
DO $test$
DECLARE result jsonb; metric jsonb;
BEGIN
 result:=public.get_paperless_bottleneck_analysis('8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-10-09 17:00Z','2026-10-10 17:00Z');
 SELECT value INTO metric FROM jsonb_array_elements(result->'stages') value WHERE value->>'stage'='kitchen';
 IF metric->>'current_count'<>'18' OR metric->'current_p90'<>'null'::jsonb THEN RAISE EXCEPTION 'Missing events/P90 threshold lost'; END IF;
END;$test$;
SELECT set_config('request.jwt.claim.sub','',true);
DO $test$ BEGIN
 BEGIN
  PERFORM public.get_paperless_bottleneck_analysis('8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-10-09','2026-10-10');
  RAISE EXCEPTION 'Anonymous accepted';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'PAPERLESS_BOTTLENECK_AUTH_REQUIRED' THEN RAISE; END IF; END;
END;$test$;
ROLLBACK;
