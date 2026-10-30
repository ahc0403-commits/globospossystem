BEGIN;
SELECT set_config('request.jwt.claim.sub','b1000000-0000-4000-8000-0000000000a1',true);

-- Synthetic, isolated workload: 100 menus, 10,000 completed lines split evenly
-- between two seven-day periods. One caller; this is not production load proof.
CREATE TEMP TABLE timing_scale_rows AS
SELECT n,
  md5('timing-order-' || n)::uuid AS order_id,
  md5('timing-line-' || n)::uuid AS line_id,
  md5('timing-menu-' || ((n - 1) % 100))::uuid AS menu_id,
  md5('timing-queue-' || n)::uuid AS queue_id,
  md5('timing-item-' || n)::uuid AS item_id,
  timestamptz '2026-09-08 01:00Z' + ((n - 1) % 7) * interval '1 day'
    + CASE WHEN n > 5000 THEN interval '7 days' ELSE interval '0' END AS received_at,
  CASE WHEN n > 5000 THEN 120 + (n % 300) ELSE 300 + (n % 200) END AS seconds
FROM generate_series(1,10000) n;
INSERT INTO public.menu_items(id,restaurant_id,name,name_ko,name_vi,name_en,price)
SELECT DISTINCT menu_id,'8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,
  'Synthetic menu','검증용 메뉴','Món kiểm thử','Synthetic menu',10000
FROM timing_scale_rows;
INSERT INTO public.orders(id,restaurant_id,status)
SELECT order_id,'8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,'completed'
FROM timing_scale_rows;
INSERT INTO public.order_items(id,restaurant_id,order_id,menu_item_id,menu_item_id_snapshot,
  label,display_name,quantity,unit_price,status,created_at)
SELECT line_id,'8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,order_id,menu_id,menu_id,
  '검증용 메뉴','Synthetic menu',1,10000,'served',received_at FROM timing_scale_rows;
INSERT INTO public.emergency_order_queue(id,session_id,order_id,restaurant_id,created_at)
SELECT queue_id,'00000000-0000-4000-8000-000000000031'::uuid,order_id,
  '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,received_at FROM timing_scale_rows;
INSERT INTO public.emergency_fulfillment_items(id,restaurant_id,session_id,order_id,
  order_item_id,ordered_quantity,kitchen_done_quantity,tray_dispatched_quantity,
  floor_served_quantity,is_cancelled)
SELECT item_id,'8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,
  '00000000-0000-4000-8000-000000000031'::uuid,order_id,line_id,1,1,1,1,false
FROM timing_scale_rows;
INSERT INTO public.emergency_fulfillment_events(session_id,order_id,restaurant_id,
  order_item_id,stage,delta,created_at)
SELECT '00000000-0000-4000-8000-000000000031'::uuid,order_id,
  '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid,line_id,'floor_served',1,
  received_at + seconds * interval '1 second' FROM timing_scale_rows;
ANALYZE;

DO $test$
DECLARE result jsonb; started timestamptz; elapsed interval; sample_count integer;
  baseline_count integer; menu_count integer;
BEGIN
  started := clock_timestamp();
  result := public.get_paperless_menu_timing_trends(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-09-14 17:00Z','2026-09-21 17:00Z');
  elapsed := clock_timestamp() - started;
  SELECT count(*), sum((value->>'current_sample_count')::integer),
    sum((value->>'baseline_sample_count')::integer)
  INTO menu_count,sample_count,baseline_count
  FROM jsonb_array_elements(result->'menus') value
  WHERE value->>'menu_key' IN (SELECT menu_id::text FROM timing_scale_rows);
  IF menu_count <> 100 OR sample_count <> 5000 OR baseline_count <> 5000 THEN
    RAISE EXCEPTION 'Scale aggregation lost samples: %, %, %',menu_count,sample_count,baseline_count;
  END IF;
  IF EXISTS (
    SELECT 1 FROM jsonb_array_elements(result->'menus') value
    JOIN (SELECT menu_id::text AS menu_key,round(avg(seconds))::integer AS mean
      FROM timing_scale_rows WHERE n > 5000 GROUP BY menu_id) expected
      ON expected.menu_key = value->>'menu_key'
    WHERE (value->>'current_average_seconds')::integer <> expected.mean
  ) THEN RAISE EXCEPTION 'Scale means must come from raw samples'; END IF;
  RAISE NOTICE 'TREND_SCALE completed_lines=10000 synthetic_menus=% current_samples=% baseline_samples=% buckets=% response_bytes=% elapsed_ms=% concurrent_callers=1',
    menu_count,sample_count,baseline_count,jsonb_array_length(result->'buckets'),
    octet_length(result::text),extract(epoch FROM elapsed)*1000;
END;
$test$;
ROLLBACK;
