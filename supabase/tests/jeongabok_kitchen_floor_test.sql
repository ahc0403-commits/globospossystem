\set ON_ERROR_STOP on
BEGIN;
DO $test$
DECLARE
  target constant uuid := '273b057e-3b69-46e3-93c1-6194c2802849';
  other constant uuid := '8bc9eef5-dcd5-46b1-b931-23f77132322c';
  session_id uuid;
  table_id uuid;
  menu uuid := gen_random_uuid();
  order_id uuid;
  order_item uuid;
  line_id uuid;
  queue_id uuid;
  other_line uuid;
  request_id uuid := gen_random_uuid();
  undo_id uuid := gen_random_uuid();
  leftover_id uuid := gen_random_uuid();
  allocations jsonb;
  result jsonb;
  before_other text;
  floor_name text;
  n integer := 0;
BEGIN
  SELECT md5(jsonb_agg(to_jsonb(a) ORDER BY a.id)::text) INTO before_other
  FROM public.emergency_station_assignments a WHERE a.restaurant_id = other;
  ASSERT NOT EXISTS (SELECT 1 FROM public.users WHERE restaurant_id = target AND fixed_account_code = 'jgbt_tray1' AND is_active);
  ASSERT EXISTS (SELECT 1 FROM public.users WHERE restaurant_id = other AND fixed_account_code = 'bt_tray1' AND is_active);
  ASSERT EXISTS (SELECT 1 FROM auth.users a JOIN public.users u ON u.auth_id = a.id
    WHERE u.fixed_account_code = 'jgbt_tray1' AND a.banned_until > now());
  BEGIN
    UPDATE public.users SET is_active = true WHERE fixed_account_code = 'jgbt_tray1';
    RAISE EXCEPTION 'CHECKER_REACTIVATION_SUCCEEDED';
  EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM = 'JEONGABOK_CHECKER_RETIRED', SQLERRM; END;
  UPDATE public.store_fixed_account_requirements SET is_active = true WHERE account_code = 'jgbt_tray1';
  ASSERT NOT EXISTS (SELECT 1 FROM public.store_fixed_account_requirements WHERE account_code = 'jgbt_tray1' AND is_active);
  PERFORM set_config('request.jwt.claims', '{"sub":"92000000-0000-4000-8000-000000000002","role":"authenticated"}', true);
  BEGIN
    PERFORM public.get_emergency_station_snapshot();
    RAISE EXCEPTION 'CHECKER_READ_SUCCEEDED';
  EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM = 'EMERGENCY_USER_REQUIRED', SQLERRM; END;
  ASSERT NOT public.kds_can_access_topic('kds:'||target||':tray');

  SELECT id INTO session_id FROM public.emergency_fulfillment_sessions WHERE restaurant_id = target AND status = 'active';
  INSERT INTO public.menu_items(id,restaurant_id,name,name_ko,name_vi,name_en,price)
  VALUES(menu,target,'Laboratory noodles','국수','Mì','Noodles',10000);
  FOREACH floor_name IN ARRAY ARRAY['1F','2F','3F'] LOOP
    n := n + 1;
    INSERT INTO public.tables(restaurant_id,table_number,floor_label)
    VALUES(target,'91'||n,floor_name) RETURNING id INTO table_id;
    INSERT INTO public.orders(restaurant_id,table_id,status) VALUES(target,table_id,'pending') RETURNING id INTO order_id;
    INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,display_name,label,quantity,unit_price,status)
    VALUES(target,order_id,menu,'Laboratory noodles','국수',2,10000,'pending') RETURNING id INTO order_item;
    SELECT i.id,i.queue_id INTO line_id,queue_id FROM public.emergency_fulfillment_items i WHERE i.order_item_id = order_item;
    ASSERT line_id IS NOT NULL, 'Kitchen line missing';
    ASSERT (SELECT q.floor_label = floor_name AND q.kitchen_direct_to_floor FROM public.emergency_order_queue q WHERE q.id = queue_id), 'Wrong direct floor';
    allocations := COALESCE(allocations,'[]'::jsonb) || jsonb_build_array(jsonb_build_object(
      'item_id',line_id,'queue_id',queue_id,'source_kind','base','quantity',2));
  END LOOP;
  PERFORM set_config('request.jwt.claims', '{"sub":"92000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  result := public.kds_complete_kitchen_batch_v1(request_id,allocations);
  ASSERT result->>'changed_quantity' = '6', result::text;
  ASSERT NOT EXISTS (SELECT 1 FROM public.emergency_fulfillment_items i WHERE i.restaurant_id = target
    AND (i.kitchen_done_quantity <> 2 OR i.tray_dispatched_quantity <> 2 OR i.tray_received_quantity <> 2 OR i.floor_served_quantity <> 0));
  ASSERT (SELECT sum(ready_quantity) = 6 FROM public.emergency_floor_ready_lots WHERE restaurant_id = target);
  ASSERT NOT EXISTS (SELECT 1 FROM public.emergency_tray_ready_lots WHERE restaurant_id = target);
  ASSERT NOT EXISTS (SELECT 1 FROM public.kds_change_log WHERE restaurant_id = target AND 'tray' = ANY(target_stations));
  result := public.kds_complete_kitchen_batch_v1(request_id,allocations);
  ASSERT result->>'deduplicated' = 'true';
  ASSERT (SELECT sum(ready_quantity) = 6 FROM public.emergency_floor_ready_lots WHERE restaurant_id = target);
  BEGIN
    PERFORM public.kds_complete_kitchen_batch_v1(request_id, jsonb_set(allocations,'{0,quantity}','1'));
    RAISE EXCEPTION 'PAYLOAD_CONFLICT_SUCCEEDED';
  EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM = 'KDS_EVENT_ID_CONFLICT', SQLERRM; END;

  -- The third-floor employee receives exactly their floor, without a checker.
  PERFORM set_config('request.jwt.claims', '{"sub":"92000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
  result := public.get_emergency_station_snapshot();
  ASSERT result->>'kitchen_direct_to_floor' = 'true';
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(result->'orders') o WHERE o->>'queue_id' = queue_id::text), result::text;
  ASSERT NOT EXISTS (SELECT 1 FROM jsonb_array_elements(result->'orders') o WHERE o->>'floor_label' <> '3F');
  ASSERT EXISTS (SELECT 1 FROM jsonb_array_elements(result->'orders') o, jsonb_array_elements(o->'items') i WHERE i->>'kitchen_direct_to_floor' = 'true');
  PERFORM public.kds_record_station_progress_v3(line_id,'base','floor_served',1,gen_random_uuid());
  PERFORM set_config('request.jwt.claims', '{"sub":"92000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  result := public.kds_record_station_progress_v3(line_id,'base','kitchen_done',-1,undo_id);
  ASSERT result->>'kitchen_done_quantity' = '1', result::text;
  result := public.kds_record_station_progress_v3(line_id,'base','kitchen_done',-1,undo_id);
  ASSERT result->>'deduplicated' = 'true';
  BEGIN
    PERFORM public.kds_record_station_progress_v3(line_id,'base','kitchen_done',-1,gen_random_uuid());
    RAISE EXCEPTION 'SERVED_KITCHEN_UNDO_SUCCEEDED';
  EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM = 'EMERGENCY_QUANTITY_CHAIN_VIOLATION', SQLERRM; END;
  result := public.emergency_record_progress(line_id,'kitchen_done',1,gen_random_uuid());
  ASSERT result->>'tray_dispatched_quantity' = '2';

  -- Leftover packaging has no hidden tray stage.
  INSERT INTO public.leftover_packaging_requests(id,session_id,restaurant_id,queue_id,order_id,
    table_number,floor_label,source,requested_by)
  VALUES(leftover_id,session_id,target,queue_id,order_id,'913','3F','staff','93000000-0000-4000-8000-000000000005');
  PERFORM set_config('request.jwt.claims', '{"sub":"92000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
  result := public.emergency_advance_leftover_packaging(leftover_id,gen_random_uuid());
  ASSERT result->>'status' = 'awaiting_kitchen_packaging', result::text;
  PERFORM set_config('request.jwt.claims', '{"sub":"92000000-0000-4000-8000-000000000001","role":"authenticated"}', true);
  result := public.emergency_advance_leftover_packaging(leftover_id,gen_random_uuid());
  ASSERT result->>'status' = 'awaiting_floor_delivery', result::text;
  PERFORM set_config('request.jwt.claims', '{"sub":"92000000-0000-4000-8000-000000000005","role":"authenticated"}', true);
  result := public.emergency_advance_leftover_packaging(leftover_id,gen_random_uuid());
  ASSERT result->>'status' = 'completed', result::text;

  -- The existing other-store kitchen -> checker -> floor flow stays intact.
  INSERT INTO public.menu_items(restaurant_id,name,price) VALUES(other,'Other store laboratory menu',10000) RETURNING id INTO menu;
  INSERT INTO public.orders(restaurant_id,status) VALUES(other,'pending') RETURNING id INTO order_id;
  INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,display_name,quantity,unit_price,status)
  VALUES(other,order_id,menu,'Other menu',1,10000,'pending') RETURNING id INTO order_item;
  SELECT i.id INTO other_line FROM public.emergency_fulfillment_items i WHERE i.order_item_id = order_item;
  BEGIN
    PERFORM public.kds_record_station_progress_v3(other_line,'base','floor_served',1,gen_random_uuid());
    RAISE EXCEPTION 'CROSS_STORE_SERVICE_SUCCEEDED';
  EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM = 'EMERGENCY_ITEM_UNAVAILABLE', SQLERRM; END;
  PERFORM set_config('request.jwt.claims', '{"sub":"92000000-0000-4000-8000-000000000006","role":"authenticated"}', true);
  PERFORM public.kds_record_station_progress_v3(other_line,'base','kitchen_done',1,gen_random_uuid());
  ASSERT (SELECT kitchen_done_quantity = 1 AND tray_dispatched_quantity = 0 FROM public.emergency_fulfillment_items WHERE id = other_line);
  ASSERT EXISTS (SELECT 1 FROM public.emergency_tray_ready_lots WHERE source_id = other_line);
  ASSERT NOT EXISTS (SELECT 1 FROM public.emergency_floor_ready_lots WHERE source_id = other_line);
  PERFORM set_config('request.jwt.claims', '{"sub":"92000000-0000-4000-8000-000000000007","role":"authenticated"}', true);
  PERFORM public.kds_record_station_progress_v3(other_line,'base','tray_dispatched',1,gen_random_uuid());
  ASSERT EXISTS (SELECT 1 FROM public.emergency_floor_ready_lots WHERE source_id = other_line);
  ASSERT before_other = (SELECT md5(jsonb_agg(to_jsonb(a) ORDER BY a.id)::text)
    FROM public.emergency_station_assignments a WHERE a.restaurant_id = other);
END;
$test$;
DO $combo$
DECLARE
 target constant uuid := '273b057e-3b69-46e3-93c1-6194c2802849';
 session_id uuid; menu uuid; oid uuid; oi uuid; parent_id uuid; qid uuid; soup uuid; main uuid;
 result jsonb; allocations jsonb;
BEGIN
 SELECT id INTO session_id FROM public.emergency_fulfillment_sessions WHERE restaurant_id=target AND status='active';
 INSERT INTO public.menu_items(restaurant_id,name,price) VALUES(target,'Combo laboratory',20000) RETURNING id INTO menu;
 INSERT INTO public.orders(restaurant_id,status) VALUES(target,'pending') RETURNING id INTO oid;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,display_name,quantity,unit_price,status)
 VALUES(target,oid,menu,'Combo laboratory',2,20000,'pending') RETURNING id INTO oi;
 SELECT id,queue_id INTO parent_id,qid FROM public.emergency_fulfillment_items WHERE order_item_id=oi;
 INSERT INTO public.emergency_combo_component_items(session_id,restaurant_id,queue_id,order_id,order_item_id,
 line_key,name_ko,name_vi,name_en,source_quantity,ordered_quantity)
 VALUES(session_id,target,qid,oid,oi,'component:1','국물','Canh','Soup',4,4) RETURNING id INTO soup;
 INSERT INTO public.emergency_combo_component_items(session_id,restaurant_id,queue_id,order_id,order_item_id,
 line_key,name_ko,name_vi,name_en,source_quantity,ordered_quantity)
 VALUES(session_id,target,qid,oid,oi,'component:2','밥','Cơm','Rice',2,2) RETURNING id INTO main;
 PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
 allocations:=jsonb_build_array(jsonb_build_object('item_id',soup,'queue_id',qid,'source_kind','combo_component','quantity',2),
 jsonb_build_object('item_id',main,'queue_id',qid,'source_kind','combo_component','quantity',1));
 result:=public.kds_complete_kitchen_batch_v1(gen_random_uuid(),allocations);
 ASSERT result->>'changed_quantity'='3';
 ASSERT (SELECT kitchen_done_quantity=1 AND tray_dispatched_quantity=1 FROM public.emergency_fulfillment_items WHERE id=parent_id);
 ASSERT (SELECT sum(ready_quantity)=3 FROM public.emergency_floor_ready_lots WHERE order_id=oid);
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_tray_ready_lots WHERE order_id=oid);
 BEGIN
  PERFORM public.kds_record_station_progress_v3(parent_id,'base','kitchen_done',1,gen_random_uuid());
  RAISE EXCEPTION 'COMBO_PARENT_MUTATION_SUCCEEDED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='KDS_COMBO_PARENT_READ_ONLY',SQLERRM; END;
 BEGIN
  PERFORM public.kds_complete_kitchen_batch_v1(gen_random_uuid(),jsonb_build_array(
   jsonb_build_object('item_id',soup,'queue_id',qid,'source_kind','combo_component','quantity',3),
   jsonb_build_object('item_id',main,'queue_id',qid,'source_kind','combo_component','quantity',1)));
  RAISE EXCEPTION 'STALE_COMBO_PARTIAL_COMMIT';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='KDS_CHECKET_SELECTION_STALE',SQLERRM; END;
 ASSERT (SELECT kitchen_done_quantity=1 FROM public.emergency_combo_component_items WHERE id=main);
 PERFORM public.kds_record_station_progress_v3(soup,'combo_component','kitchen_done',-1,gen_random_uuid());
 ASSERT (SELECT kitchen_done_quantity=0 AND tray_dispatched_quantity=0 FROM public.emergency_fulfillment_items WHERE id=parent_id);
 ASSERT (SELECT sum(ready_quantity-served_quantity-voided_quantity)=2 FROM public.emergency_floor_ready_lots WHERE order_id=oid);
END;
$combo$;
DO $bounds$
DECLARE menu uuid; oid uuid; oi uuid; iid uuid; qid uuid; result jsonb;
BEGIN
 INSERT INTO public.menu_items(restaurant_id,name,price)
 VALUES('273b057e-3b69-46e3-93c1-6194c2802849','Quantity bound laboratory',10000) RETURNING id INTO menu;
 INSERT INTO public.orders(restaurant_id,status) VALUES('273b057e-3b69-46e3-93c1-6194c2802849','pending') RETURNING id INTO oid;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,display_name,quantity,unit_price,status)
 VALUES('273b057e-3b69-46e3-93c1-6194c2802849',oid,menu,'Quantity bound laboratory',1000,10000,'pending') RETURNING id INTO oi;
 SELECT id,queue_id INTO iid,qid FROM public.emergency_fulfillment_items WHERE order_item_id=oi;
 PERFORM set_config('request.jwt.claims','{"sub":"92000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
 BEGIN
  PERFORM public.kds_complete_kitchen_batch_v1(gen_random_uuid(),jsonb_build_array(
   jsonb_build_object('item_id',iid,'queue_id',qid,'source_kind','base','quantity',1001)));
  RAISE EXCEPTION 'BATCH_BOUND_EXCEEDED';
 EXCEPTION WHEN OTHERS THEN ASSERT SQLERRM='KDS_CHECKET_BATCH_INPUT_INVALID',SQLERRM; END;
 result:=public.kds_complete_kitchen_batch_v1(gen_random_uuid(),jsonb_build_array(
   jsonb_build_object('item_id',iid,'queue_id',qid,'source_kind','base','quantity',1000)));
 ASSERT result->>'changed_quantity'='1000';
 ASSERT jsonb_array_length(result->'event_ids')=1;
 ASSERT (SELECT sum(ready_quantity)=1000 FROM public.emergency_floor_ready_lots WHERE order_id=oid);
 ASSERT (SELECT count(*)=1 FROM public.emergency_fulfillment_events WHERE order_id=oid AND stage='kitchen_done');
END;
$bounds$;
SET CONSTRAINTS ALL IMMEDIATE;
DO $$ BEGIN
  ASSERT NOT EXISTS(SELECT 1 FROM realtime.kds_lab_messages
    WHERE topic IN ('kds:273b057e-3b69-46e3-93c1-6194c2802849:tray',
      'kds:273b057e-3b69-46e3-93c1-6194c2802849:control'));
  ASSERT EXISTS(SELECT 1 FROM realtime.kds_lab_messages
    WHERE topic='kds:273b057e-3b69-46e3-93c1-6194c2802849:floor:3F');
  ASSERT EXISTS(SELECT 1 FROM realtime.kds_lab_messages
    WHERE topic='kds:8bc9eef5-dcd5-46b1-b931-23f77132322c:tray');
END $$;
ROLLBACK;
SELECT 'JEONGABOK_DIRECT_FLOOR_REGRESSION=PASS';
