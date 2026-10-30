-- Isolated seeded JeonGabok fixture only. Every row created here rolls back.
\set ON_ERROR_STOP on
BEGIN;
DO $$ DECLARE
 target constant uuid := '273b057e-3b69-46e3-93c1-6194c2802849';
 menu uuid; tid uuid; oid uuid; oi uuid; line uuid; qid uuid;
 start_id uuid:=gen_random_uuid(); handoff_id uuid:=gen_random_uuid(); check_id uuid:=gen_random_uuid(); result jsonb;
 component uuid;
BEGIN
 ASSERT EXISTS(SELECT 1 FROM auth.users WHERE id='92000000-0000-4000-8000-000000000001' AND email='kds-lab-1@internal.invalid');
 INSERT INTO public.menu_items(restaurant_id,name,price)
 VALUES(target,'Explicit handoff regression '||gen_random_uuid(),10000) RETURNING id INTO menu;
 INSERT INTO public.tables(restaurant_id,table_number,floor_label)
 VALUES(target,'regression-'||gen_random_uuid(),'3F') RETURNING id INTO tid;
 INSERT INTO public.orders(restaurant_id,table_id,status) VALUES(target,tid,'pending') RETURNING id INTO oid;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,display_name,quantity,unit_price,status)
 VALUES(target,oid,menu,'Explicit handoff regression',2,10000,'pending') RETURNING id INTO oi;
 SELECT id,queue_id INTO line,qid FROM public.emergency_fulfillment_items WHERE order_item_id=oi;
 ASSERT line IS NOT NULL;
 PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
 result:=public.kds_record_station_progress_v3(line,'base','kitchen_started',1,start_id);
 ASSERT result->>'kitchen_started_quantity'='1' AND result->>'kitchen_done_quantity'='0',result::text;
 result:=public.kds_record_station_progress_v3(line,'base','kitchen_started',1,start_id);
 ASSERT result->>'deduplicated'='true';
 PERFORM public.kds_record_station_progress_v3(line,'base','kitchen_started',1,gen_random_uuid());
 ASSERT (SELECT kitchen_started_quantity=2 AND kitchen_done_quantity=0 AND tray_dispatched_quantity=0 FROM public.emergency_fulfillment_items WHERE id=line);
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_floor_ready_lots WHERE source_id=line);
 ASSERT NOT EXISTS(SELECT 1 FROM public.kds_change_log WHERE event_id=start_id AND 'floor'=ANY(target_stations));
 PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000005","role":"authenticated"}',true);
 BEGIN
  PERFORM public.kds_record_station_progress_v3(line,'base','floor_served',1,gen_random_uuid());
  RAISE EXCEPTION 'UNHANDED_FOOD_WAS_SERVABLE';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='EMERGENCY_QUANTITY_CHAIN_VIOLATION',SQLERRM; END;
 PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
 result:=public.kds_complete_kitchen_batch_v1(handoff_id,jsonb_build_array(jsonb_build_object('item_id',line,'queue_id',qid,'source_kind','base','quantity',1)));
 ASSERT result->>'changed_quantity'='1',result::text;
 ASSERT (SELECT kitchen_started_quantity=2 AND kitchen_done_quantity=1 AND tray_dispatched_quantity=1 AND floor_served_quantity=0 FROM public.emergency_fulfillment_items WHERE id=line);
 ASSERT (SELECT sum(ready_quantity-served_quantity-voided_quantity)=1 FROM public.emergency_floor_ready_lots WHERE source_id=line);
 result:=public.kds_complete_kitchen_batch_v1(handoff_id,jsonb_build_array(jsonb_build_object('item_id',line,'queue_id',qid,'source_kind','base','quantity',1)));
 ASSERT result->>'deduplicated'='true';
 -- The order-detail check uses the single-item station RPC, independently of
 -- the existing global handoff sheet. A repeated event must not hand off twice.
 result:=public.kds_record_station_progress_v3(line,'base','kitchen_done',1,check_id);
 ASSERT result->>'kitchen_done_quantity'='2',result::text;
 result:=public.kds_record_station_progress_v3(line,'base','kitchen_done',1,check_id);
 ASSERT result->>'deduplicated'='true',result::text;
 ASSERT (SELECT kitchen_started_quantity=2 AND kitchen_done_quantity=2 AND tray_dispatched_quantity=2 FROM public.emergency_fulfillment_items WHERE id=line);
 ASSERT (SELECT sum(ready_quantity-served_quantity-voided_quantity)=2 FROM public.emergency_floor_ready_lots WHERE source_id=line);

 -- A component and its parent must also retain previously started quantities.
 INSERT INTO public.orders(restaurant_id,table_id,status) VALUES(target,tid,'pending') RETURNING id INTO oid;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,display_name,quantity,unit_price,status)
 VALUES(target,oid,menu,'Component handoff regression',2,10000,'pending') RETURNING id INTO oi;
 SELECT id,queue_id INTO line,qid FROM public.emergency_fulfillment_items WHERE order_item_id=oi;
 INSERT INTO public.emergency_combo_component_items(session_id,restaurant_id,queue_id,order_id,order_item_id,line_key,name_ko,name_vi,name_en,source_quantity,ordered_quantity)
 SELECT session_id,target,qid,oid,oi,'component:regression','회귀','Hồi quy','Regression',2,2 FROM public.emergency_fulfillment_items WHERE id=line RETURNING id INTO component;
 PERFORM public.kds_record_station_progress_v3(component,'combo_component','kitchen_started',1,gen_random_uuid());
 PERFORM public.kds_record_station_progress_v3(component,'combo_component','kitchen_started',1,gen_random_uuid());
 PERFORM public.kds_complete_kitchen_batch_v1(gen_random_uuid(),jsonb_build_array(jsonb_build_object('item_id',component,'queue_id',qid,'source_kind','combo_component','quantity',1)));
 ASSERT (SELECT kitchen_started_quantity=2 AND kitchen_done_quantity=1 FROM public.emergency_combo_component_items WHERE id=component);
 ASSERT (SELECT kitchen_started_quantity=2 AND kitchen_done_quantity=1 FROM public.emergency_fulfillment_items WHERE id=line);
 PERFORM public.kds_record_station_progress_v3(component,'combo_component','kitchen_done',1,gen_random_uuid());
 ASSERT (SELECT kitchen_started_quantity=2 AND kitchen_done_quantity=2 AND tray_dispatched_quantity=2 FROM public.emergency_combo_component_items WHERE id=component);
 ASSERT (SELECT kitchen_started_quantity=2 AND kitchen_done_quantity=2 FROM public.emergency_fulfillment_items WHERE id=line);
END $$;
ROLLBACK;
SELECT 'JEONGABOK_EXPLICIT_FLOOR_HANDOFF=PASS';
