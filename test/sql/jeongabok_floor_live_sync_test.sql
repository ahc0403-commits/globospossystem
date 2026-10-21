INSERT INTO public.emergency_fulfillment_events(session_id,restaurant_id,order_id,stage,delta)
VALUES('10000000-0000-4000-8000-000000000001','273b057e-3b69-46e3-93c1-6194c2802849','20000000-0000-4000-8000-000000000001','kitchen_done',1);
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.kds_change_log WHERE payload->>'stage'='kitchen_done' AND target_stations=ARRAY['kitchen','floor'] AND target_floor_label='2F')
 OR NOT EXISTS(SELECT 1 FROM realtime.kds_lab_messages WHERE topic='kds:273b057e-3b69-46e3-93c1-6194c2802849:floor:2F' AND payload->'payload'->>'stage'='kitchen_done')
 OR EXISTS(SELECT 1 FROM realtime.kds_lab_messages WHERE topic LIKE '%:tray')
 THEN RAISE EXCEPTION 'DIRECT_FLOOR_DELIVERY_MISSING'; END IF;
END $$;

-- Actual item/component lookup stays scoped and never multiplies sibling items.
INSERT INTO public.menu_items VALUES
 ('60000000-0000-4000-8000-000000000001','Tên bếp'),
 ('60000000-0000-4000-8000-000000000002','Tên đồ uống');
INSERT INTO public.order_items VALUES('50000000-0000-4000-8000-000000000001','60000000-0000-4000-8000-000000000001');
INSERT INTO public.emergency_floor_direct_items VALUES('40000000-0000-4000-8000-000000000002','60000000-0000-4000-8000-000000000002');
INSERT INTO public.emergency_combo_component_items(id,queue_id,order_item_id,line_key,name_ko,name_vi,name_en,component_menu_item_id,is_cancelled,created_at)
VALUES
 ('70000000-0000-4000-8000-000000000001','30000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001','first','음식','기존','Dish','60000000-0000-4000-8000-000000000001',false,now()),
 ('70000000-0000-4000-8000-000000000002','30000000-0000-4000-8000-000000000001','50000000-0000-4000-8000-000000000001','cancelled','취소','기존','Cancelled',null,true,now()),
 ('70000000-0000-4000-8000-000000000003','30000000-0000-4000-8000-000000000099','50000000-0000-4000-8000-000000000001','other-queue','다른 주문','기존','Other queue',null,false,now());
DO $$ DECLARE result jsonb; BEGIN
 result:=public.emergency_localize_paperless_orders(jsonb_build_array(jsonb_build_object('queue_id','30000000-0000-4000-8000-000000000001','items',jsonb_build_array(
  jsonb_build_object('order_item_id','50000000-0000-4000-8000-000000000001','combo_components',jsonb_build_array(jsonb_build_object('menu_item_id','60000000-0000-4000-8000-000000000002'))),
  jsonb_build_object('id','40000000-0000-4000-8000-000000000002','fulfillment_route','floor_direct'),jsonb_build_object('name_vi','')))));
 IF result->0->'items'->0->>'name_vi'<>'Tên bếp' OR result->0->'items'->0->'combo_components'->0->>'name_vi'<>'Tên đồ uống'
 OR result->0->'items'->1->>'name_vi'<>'Tên đồ uống' OR result->0->'items'->2->>'name_vi'<>'Món' THEN RAISE EXCEPTION 'LOCALIZED_NAMES_OR_ITEM_ORDER_LOST'; END IF;
 result:=public.emergency_add_combo_component_progress(result);
 IF jsonb_array_length(result->0->'items')<>4 OR result->0->'items'->3->>'line_key'<>'first' OR result->0->'items'->3->>'name_vi'<>'Tên bếp' THEN RAISE EXCEPTION 'COMPONENT_SCOPE_OR_ORDER_LOST'; END IF;
 IF public.emergency_localize_paperless_orders(null)<>'[]'::jsonb OR public.emergency_add_combo_component_progress('{}')<>'[]'::jsonb THEN RAISE EXCEPTION 'EMPTY_PAYLOAD_REGRESSION'; END IF;
END $$;
-- Stored 3F remains 3F on the private floor topic.
UPDATE public.emergency_order_queue SET floor_label='3F';
INSERT INTO public.emergency_fulfillment_events(session_id,restaurant_id,order_id,stage,delta)
VALUES('10000000-0000-4000-8000-000000000001','273b057e-3b69-46e3-93c1-6194c2802849','20000000-0000-4000-8000-000000000001','kitchen_done',1);
DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM realtime.kds_lab_messages WHERE topic='kds:273b057e-3b69-46e3-93c1-6194c2802849:floor:3F' AND payload->'payload'->>'stage'='kitchen_done') THEN RAISE EXCEPTION 'THIRD_FLOOR_SIGNAL_LOST'; END IF;
END $$;
-- Delivery preparation never enters a table floor channel.
UPDATE public.orders SET sales_channel='delivery';
INSERT INTO public.emergency_fulfillment_events(session_id,restaurant_id,order_id,stage,delta)
VALUES('10000000-0000-4000-8000-000000000001','273b057e-3b69-46e3-93c1-6194c2802849','20000000-0000-4000-8000-000000000001','kitchen_done',1);
DO $$ BEGIN
 IF EXISTS(SELECT 1 FROM public.kds_change_log WHERE (payload->>'no_floor_delivery')::boolean AND 'floor'=ANY(target_stations)) THEN RAISE EXCEPTION 'DELIVERY_SENT_TO_FLOOR'; END IF;
 IF EXISTS(SELECT 1 FROM public.kds_realtime_rollouts WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c') THEN RAISE EXCEPTION 'OTHER_STORE_ROLLOUT_CHANGED'; END IF;
END $$;
SELECT 'JEONGABOK_FLOOR_LIVE_SYNC_SQL=PASS';

-- Scope-limited set enrichment preserves item order, fallback names and counts.
DO $$ DECLARE payload jsonb; result jsonb; BEGIN
 SELECT jsonb_agg(jsonb_build_object('queue_id','30000000-0000-4000-8000-000000000001','items',jsonb_build_array(jsonb_build_object(
  'id','40000000-0000-4000-8000-000000000001','order_item_id','50000000-0000-4000-8000-000000000001','name_vi','Fallback','combo_components','[]'::jsonb)))) INTO payload FROM generate_series(1,500);
 result:=public.emergency_localize_paperless_orders(payload);
 IF jsonb_array_length(result)<>500 OR result->0->'items'->0->>'name_vi'<>'Tên bếp' THEN RAISE EXCEPTION 'BATCH_LOCALIZATION_LOST_ITEMS'; END IF;
 result:=public.emergency_add_combo_component_progress(result);
 IF jsonb_array_length(result)<>500 OR jsonb_array_length(result->0->'items')<>2 THEN RAISE EXCEPTION 'BATCH_COMPONENTS_MULTIPLIED'; END IF;
END $$;
EXPLAIN (ANALYZE,BUFFERS) WITH payload AS (
 SELECT jsonb_agg(jsonb_build_object('queue_id','30000000-0000-4000-8000-000000000001','items',jsonb_build_array(jsonb_build_object('order_item_id','50000000-0000-4000-8000-000000000001')))) value FROM generate_series(1,500)
) SELECT octet_length(public.emergency_add_combo_component_progress(public.emergency_localize_paperless_orders(value))::text) FROM payload;
SELECT 'JEONGABOK_BATCH_ENRICHMENT=PASS';
