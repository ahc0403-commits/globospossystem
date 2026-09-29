BEGIN;
SELECT set_config('request.jwt.claim.sub','b1000000-0000-4000-8000-0000000000a1',true);

-- One unpaid order has both kitchen and floor-direct drink samples.
INSERT INTO public.orders(id,restaurant_id,status) VALUES
  ('00000000-0000-4000-8000-000000000004',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c','completed');
INSERT INTO public.order_items(id,restaurant_id,order_id,menu_item_id,
  menu_item_id_snapshot,label,display_name,quantity,unit_price,status,
  paying_amount_inc_tax,created_at) VALUES
  ('00000000-0000-4000-8000-000000000016',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000004',
   '53249604-fd2e-40f5-a776-3e1bc5f32153',
   '53249604-fd2e-40f5-a776-3e1bc5f32153',
   '코카콜라 일반','코카콜라 일반',1,10000,'served',10000,'2026-09-15 11:00Z'),
  ('00000000-0000-4000-8000-000000000017',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000004',
   '4eda734f-4ac9-4f05-9eeb-0a4e4b122988',
   '4eda734f-4ac9-4f05-9eeb-0a4e4b122988',
   'Sting','Sting',1,15000,'served',15000,'2026-09-15 11:01Z');
INSERT INTO public.emergency_order_queue(id,session_id,order_id,restaurant_id,created_at) VALUES
  ('00000000-0000-4000-8000-000000000044',
   '00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000004',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-09-15 11:00Z'),
  ('00000000-0000-4000-8000-000000000045',
   '00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000003',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c','2026-09-29 10:00Z');
INSERT INTO public.emergency_fulfillment_items(id,restaurant_id,session_id,
  order_id,order_item_id,ordered_quantity,kitchen_done_quantity,
  tray_dispatched_quantity,floor_served_quantity,is_cancelled) VALUES
  ('00000000-0000-4000-8000-000000000054',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000004',
   '00000000-0000-4000-8000-000000000016',1,1,1,1,false),
  ('00000000-0000-4000-8000-000000000058',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000003',
   '00000000-0000-4000-8000-000000000015',1,1,1,1,false);

-- Floor-direct and combo components can carry an old component menu ID
-- even when their parent order_item points at a different menu.
INSERT INTO public.emergency_floor_direct_items(id,restaurant_id,session_id,
  order_id,order_item_id,component_menu_item_id,name_ko,name_vi,name_en,
  ordered_quantity,floor_served_quantity,is_cancelled) VALUES
  ('00000000-0000-4000-8000-000000000055',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000001',
   '00000000-0000-4000-8000-000000000012',
   '4eda734f-4ac9-4f05-9eeb-0a4e4b122988','Sting','Sting','Sting',1,1,false),
  ('00000000-0000-4000-8000-000000000057',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000004',
   '00000000-0000-4000-8000-000000000017',
   '4eda734f-4ac9-4f05-9eeb-0a4e4b122988','Sting','Sting','Sting',1,1,false);
INSERT INTO public.emergency_combo_component_items(id,restaurant_id,
  session_id,order_id,order_item_id,component_menu_item_id,name_ko,name_vi,
  name_en,ordered_quantity,kitchen_done_quantity,tray_dispatched_quantity,
  floor_served_quantity,is_cancelled) VALUES
  ('00000000-0000-4000-8000-000000000056',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000001',
   '00000000-0000-4000-8000-000000000012',
   '53249604-fd2e-40f5-a776-3e1bc5f32153',
   '코카콜라 일반','Coca-Cola','Coca-Cola',1,1,1,1,false);
INSERT INTO public.emergency_fulfillment_events(session_id,order_id,
  restaurant_id,order_item_id,floor_direct_item_id,combo_component_item_id,
  stage,delta,created_at) VALUES
  ('00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000004',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000016',NULL,NULL,
   'kitchen_done',1,'2026-09-15 11:02Z'),
  ('00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000004',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000016',NULL,NULL,
   'tray_dispatched',1,'2026-09-15 11:03Z'),
  ('00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000004',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000016',NULL,NULL,
   'floor_served',1,'2026-09-15 11:04Z'),
  ('00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000003',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000015',NULL,NULL,
   'kitchen_done',1,'2026-09-29 10:02Z'),
  ('00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000003',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000015',NULL,NULL,
   'tray_dispatched',1,'2026-09-29 10:03Z'),
  ('00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000003',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000015',NULL,NULL,
   'floor_served',1,'2026-09-29 10:04Z'),
  ('00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000001',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   NULL,'00000000-0000-4000-8000-000000000055',NULL,
   'floor_served',1,'2026-09-15 10:07Z'),
  ('00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000004',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   NULL,'00000000-0000-4000-8000-000000000057',NULL,
   'floor_served',1,'2026-09-15 11:04Z'),
  ('00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000001',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000012',NULL,
   '00000000-0000-4000-8000-000000000056',
   'kitchen_done',1,'2026-09-15 10:03Z'),
  ('00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000001',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000012',NULL,
   '00000000-0000-4000-8000-000000000056',
   'tray_dispatched',1,'2026-09-15 10:04Z'),
  ('00000000-0000-4000-8000-000000000031',
   '00000000-0000-4000-8000-000000000001',
   '8bc9eef5-dcd5-46b1-b931-23f77132322c',
   '00000000-0000-4000-8000-000000000012',NULL,
   '00000000-0000-4000-8000-000000000056',
   'floor_served',1,'2026-09-15 10:05Z');

DO $test$
DECLARE result jsonb;
BEGIN
  result := public.get_paperless_operations_report(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c',
    '2026-09-14 17:00Z','2026-09-15 17:00Z');
  IF (SELECT count(*) FROM jsonb_array_elements(result->'menu_operation_times') row
      WHERE row->>'menu_key' IN (
        '53249604-fd2e-40f5-a776-3e1bc5f32153',
        '4eda734f-4ac9-4f05-9eeb-0a4e4b122988')) <> 0
     OR (SELECT (row->>'sample_count')::integer
         FROM jsonb_array_elements(result->'menu_operation_times') row
         WHERE row->>'menu_key' = '1917ec7d-c11e-4ed6-aced-c679d2104fba') <> 3
     OR (SELECT (row->>'sample_count')::integer
         FROM jsonb_array_elements(result->'menu_operation_times') row
         WHERE row->>'menu_key' = '8ce1a136-f51a-4ee6-a14e-73184a874646') <> 3 THEN
    RAISE EXCEPTION 'Paperless residual name correction mismatch: %',
      result->'menu_operation_times';
  END IF;
  result := public.get_paperless_operations_report(
    '8bc9eef5-dcd5-46b1-b931-23f77132322c',
    '2026-09-28 17:00Z','2026-09-29 17:00Z');
  IF (SELECT count(*) FROM jsonb_array_elements(result->'menu_operation_times') row
      WHERE row->>'menu_key' = '53249604-fd2e-40f5-a776-3e1bc5f32153'
        AND row->>'name_ko' = '코카콜라 일반') <> 1 THEN
    RAISE EXCEPTION 'Paperless correction escaped business date: %',
      result->'menu_operation_times';
  END IF;

  IF (public.get_paperless_menu_timing_detail(
        '8bc9eef5-dcd5-46b1-b931-23f77132322c',
        '2026-09-14 17:00Z','2026-09-15 17:00Z',
        '1917ec7d-c11e-4ed6-aced-c679d2104fba',NULL,50,NULL,NULL)
      ->>'total_count')::integer <> 3
     OR (public.get_paperless_menu_timing_detail(
        '8bc9eef5-dcd5-46b1-b931-23f77132322c',
        '2026-09-14 17:00Z','2026-09-15 17:00Z',
        '8ce1a136-f51a-4ee6-a14e-73184a874646',NULL,50,NULL,NULL)
      ->>'total_count')::integer <> 3
     OR (public.get_paperless_menu_timing_detail(
        '8bc9eef5-dcd5-46b1-b931-23f77132322c',
        '2026-09-14 17:00Z','2026-09-15 17:00Z',
        '53249604-fd2e-40f5-a776-3e1bc5f32153',NULL,50,NULL,NULL)
      ->>'total_count')::integer <> 0
     OR (public.get_paperless_menu_timing_detail(
        '8bc9eef5-dcd5-46b1-b931-23f77132322c',
        '2026-09-28 17:00Z','2026-09-29 17:00Z',
        '53249604-fd2e-40f5-a776-3e1bc5f32153',NULL,50,NULL,NULL)
      ->>'total_count')::integer <> 1 THEN
    RAISE EXCEPTION 'Paperless drill-down identity or scope mismatch';
  END IF;
END $test$;
ROLLBACK;
