BEGIN;
SELECT set_config('request.jwt.claim.sub','b1000000-0000-4000-8000-0000000000a1',true);

-- Completed line sample on the next Vietnam business day, after midnight UTC+7.
INSERT INTO public.orders(id,restaurant_id,status) VALUES
  ('00000000-0000-4000-8000-000000000901','8bc9eef5-dcd5-46b1-b931-23f77132322c','completed');
INSERT INTO public.order_items(id,restaurant_id,order_id,menu_item_id,
  menu_item_id_snapshot,label,display_name,quantity,unit_price,status,created_at) VALUES
  ('00000000-0000-4000-8000-000000000902','8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000901','53249604-fd2e-40f5-a776-3e1bc5f32153',
   '53249604-fd2e-40f5-a776-3e1bc5f32153','코카콜라 일반','Coca-Cola',1,10000,'served','2026-09-15 17:30Z');
INSERT INTO public.emergency_order_queue(id,session_id,order_id,restaurant_id,created_at) VALUES
  ('00000000-0000-4000-8000-000000000903','00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000901','8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-09-15 17:30Z');
INSERT INTO public.emergency_fulfillment_items(id,restaurant_id,session_id,
  order_id,order_item_id,ordered_quantity,kitchen_done_quantity,
  tray_dispatched_quantity,floor_served_quantity,is_cancelled) VALUES
  ('00000000-0000-4000-8000-000000000904','8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000901',
   '00000000-0000-4000-8000-000000000902',1,1,1,1,false);
INSERT INTO public.emergency_fulfillment_events(session_id,order_id,restaurant_id,
  order_item_id,stage,delta,created_at) VALUES
  ('00000000-0000-4000-8000-000000000031','00000000-0000-4000-8000-000000000901',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c','00000000-0000-4000-8000-000000000902',
   'floor_served',1,'2026-09-15 17:32Z');

DO $test$
DECLARE result jsonb; menu jsonb; canonical jsonb; elapsed interval; started timestamptz;
BEGIN
  started := clock_timestamp();
  result := public.get_paperless_menu_timing_trends(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-09-15 17:00Z','2026-09-16 17:00Z');
  elapsed := clock_timestamp() - started;
  IF result->>'baseline_from' <> '2026-09-15'
    OR result->>'baseline_to' <> '2026-09-15'
    OR result->'buckets'->0->>'from_date' <> '2026-09-16'
    OR jsonb_array_length(result->'buckets') <> 1 THEN
    RAISE EXCEPTION 'Wrong Vietnam dates or baseline: %', result;
  END IF;
  SELECT value INTO menu FROM jsonb_array_elements(result->'menus')
    WHERE value->>'menu_key' = '1917ec7d-c11e-4ed6-aced-c679d2104fba';
  canonical := public.get_paperless_operations_report(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-09-14 17:00Z','2026-09-15 17:00Z');
  IF menu IS NULL OR (menu->>'current_average_seconds')::integer <> 120
     OR (menu->>'current_sample_count')::integer <> 1
     OR menu->>'name_ko' <> '코카콜라 제로'
     OR NOT EXISTS (SELECT 1 FROM jsonb_array_elements(canonical->'menu_operation_times') value
       WHERE value->>'menu_key' = menu->>'menu_key'
         AND value->>'sample_count' = menu->>'baseline_sample_count'
         AND value->>'operation_average_seconds' = menu->>'baseline_average_seconds') THEN
    RAISE EXCEPTION 'Baseline must match canonical corrected samples: % / %', menu, canonical;
  END IF;
  IF (menu->'points'->0->>'average_seconds')::integer <> 120 THEN
    RAISE EXCEPTION 'Wrong bucket mean';
  END IF;
  RAISE NOTICE 'TREND_FIXTURE bytes=% menus=% elapsed_ms=%',
    octet_length(result::text), jsonb_array_length(result->'menus'),
    extract(epoch FROM elapsed)*1000;

  result := public.get_paperless_menu_timing_trends(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-09-14 17:00Z','2026-09-16 17:00Z');
  SELECT value INTO menu FROM jsonb_array_elements(result->'menus')
    WHERE value->>'menu_key' = '1917ec7d-c11e-4ed6-aced-c679d2104fba';
  IF menu->'baseline_average_seconds' <> 'null'::jsonb
    OR (menu->>'baseline_sample_count')::integer <> 0
    OR jsonb_array_length(menu->'points') <> 2 THEN
    RAISE EXCEPTION 'Missing baseline is not zero; preserve both daily buckets';
  END IF;
  result := public.get_paperless_menu_timing_trends(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-08-31 17:00Z','2026-09-30 17:00Z');
  IF result->>'bucket_unit' <> 'week' OR jsonb_array_length(result->'buckets') > 6 THEN
    RAISE EXCEPTION 'Wrong weekly bucketing';
  END IF;
  result := public.get_paperless_menu_timing_trends(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c','2025-12-31 17:00Z','2026-12-31 17:00Z');
  IF result->>'bucket_unit' <> 'month' OR jsonb_array_length(result->'buckets') <> 12 THEN
    RAISE EXCEPTION 'Wrong calendar month bucketing';
  END IF;
  result := public.get_paperless_menu_timing_trends(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c','2024-01-01','2024-01-03');
  IF result->'menus' <> '[]'::jsonb THEN RAISE EXCEPTION 'Empty range leaked samples'; END IF;

  BEGIN
    PERFORM public.get_paperless_menu_timing_trends(
      '8bc9eef5-dcd5-46b1-b931-23f77132322c','2025-01-01','2026-01-03');
    RAISE EXCEPTION 'Invalid range accepted';
  EXCEPTION WHEN raise_exception THEN
    IF SQLERRM <> 'PAPERLESS_REPORT_RANGE_INVALID' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM public.get_paperless_menu_timing_trends(
      'b1000000-0000-4000-8000-000000000005','2026-09-15','2026-09-16');
    RAISE EXCEPTION 'Cross-store read accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'ADMIN_MUTATION_FORBIDDEN' THEN RAISE; END IF;
  END;
END;
$test$;


-- Duplicate queue entries spanning the baseline/current boundary do not erase
-- the current cohort; each cohort still agrees with its canonical report.
INSERT INTO public.emergency_order_queue(id,session_id,order_id,restaurant_id,created_at) VALUES
  ('00000000-0000-4000-8000-000000000905','00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000901','8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-09-15 10:30Z');
DO $test$
DECLARE result jsonb; menu jsonb;
BEGIN
  result := public.get_paperless_menu_timing_trends(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-09-15 17:00Z','2026-09-16 17:00Z');
  SELECT value INTO menu FROM jsonb_array_elements(result->'menus')
    WHERE value->>'menu_key' = '1917ec7d-c11e-4ed6-aced-c679d2104fba';
  IF (menu->>'current_sample_count')::integer <> 1
    OR (menu->>'baseline_sample_count')::integer <> 3 THEN
    RAISE EXCEPTION 'Cross-period queue deduplication lost or duplicated samples: %', menu;
  END IF;
END;
$test$;

SELECT set_config('request.jwt.claim.sub','',true);
DO $test$
BEGIN
  BEGIN
    PERFORM public.get_paperless_menu_timing_trends(
      '8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-09-15','2026-09-16');
    RAISE EXCEPTION 'Unauthenticated read accepted';
  EXCEPTION WHEN OTHERS THEN
    IF SQLERRM <> 'PAPERLESS_TREND_AUTH_REQUIRED' THEN RAISE; END IF;
  END;
END;
$test$;
ROLLBACK;
