\set ON_ERROR_STOP on
BEGIN;
SET LOCAL TIME ZONE 'Asia/Ho_Chi_Minh';
SET LOCAL statement_timeout='15s';
-- Changes below arrange read fixtures; operational write triggers are out of scope.
SET LOCAL session_replication_role=replica;
-- Tied timestamps, cancellation and a reopened line exercise cursor boundaries.
UPDATE emergency_fulfillment_events SET created_at=date_trunc('day',now())+interval '1 second'
WHERE order_id IN(SELECT id FROM orders WHERE created_at>=date_trunc('day',now()) LIMIT 15);
UPDATE emergency_fulfillment_items SET floor_served_quantity=0
WHERE order_id=(SELECT id FROM orders WHERE created_at>=date_trunc('day',now()) ORDER BY id LIMIT 1);
UPDATE emergency_fulfillment_items SET is_cancelled=true
WHERE order_id=(SELECT id FROM orders WHERE created_at>=date_trunc('day',now()) ORDER BY id OFFSET 1 LIMIT 1);

-- Registered choice snapshots, combo projection and direct beverage history.
UPDATE order_items SET notes='fixture note',is_takeout=true,menu_option_snapshot=jsonb_build_object(
 'name_ko','고정 메뉴','name_vi','Món cố định','name_en','Frozen dish','components',
 jsonb_build_object('1',jsonb_build_object('name_ko','구성','name_vi','Phần','name_en','Component')))
WHERE id=(SELECT oi.id FROM order_items oi JOIN orders o ON o.id=oi.order_id WHERE o.created_at>=date_trunc('day',now()) ORDER BY oi.id DESC LIMIT 1);
INSERT INTO emergency_combo_component_items(id,session_id,restaurant_id,queue_id,order_id,order_item_id,
 component_menu_item_id,line_key,name_ko,name_vi,name_en,source_quantity,ordered_quantity,kitchen_started_quantity,
 kitchen_done_quantity,tray_received_quantity,tray_dispatched_quantity,floor_served_quantity)
SELECT kds_test.id(800001),f.session_id,f.restaurant_id,f.queue_id,f.order_id,f.order_item_id,
 kds_test.id(900040),'component:1','구성','Phần','Component',1,1,1,1,1,1,1 FROM emergency_fulfillment_items f
JOIN order_items oi ON oi.id=f.order_item_id WHERE oi.notes='fixture note';
INSERT INTO emergency_fulfillment_events(event_id,session_id,restaurant_id,order_id,order_item_id,combo_component_item_id,stage,delta,created_at)
SELECT kds_test.id(800010+s),c.session_id,c.restaurant_id,c.order_id,c.order_item_id,c.id,
 CASE s WHEN 0 THEN 'kitchen_done' WHEN 1 THEN 'tray_dispatched' ELSE 'floor_served' END,1,date_trunc('day',now())+interval '2 seconds'
FROM emergency_combo_component_items c CROSS JOIN generate_series(0,2)s WHERE c.id=kds_test.id(800001);
INSERT INTO emergency_floor_direct_items(id,session_id,restaurant_id,queue_id,order_id,order_item_id,
 component_menu_item_id,line_key,source_kind,name_ko,name_vi,name_en,source_quantity,ordered_quantity,floor_served_quantity)
SELECT kds_test.id(800002),f.session_id,f.restaurant_id,f.queue_id,f.order_id,f.order_item_id,
 kds_test.id(900040),'direct:1','order_item','음료','Nước','Drink',1,1,1 FROM emergency_fulfillment_items f
JOIN order_items oi ON oi.id=f.order_item_id WHERE oi.notes='fixture note';
INSERT INTO emergency_fulfillment_events(event_id,session_id,restaurant_id,order_id,order_item_id,floor_direct_item_id,stage,delta,created_at)
SELECT kds_test.id(800020),d.session_id,d.restaurant_id,d.order_id,d.order_item_id,d.id,'floor_served',1,date_trunc('day',now())+interval '3 seconds'
FROM emergency_floor_direct_items d WHERE d.id=kds_test.id(800002);
-- A real direct-order relation exercises pickup visibility and packing notes.
INSERT INTO direct_order_requests(id,restaurant_id,session_id,client_request_id,reference_code,
 fulfillment_type,fulfillment_method,diner_count,utensils_requested)
VALUES(kds_test.id(800030),'8bc9eef5-dcd5-46b1-b931-23f77132322c',kds_test.id(800031),kds_test.id(800032),
 'DTEST0001','pickup','pickup',2,true);
INSERT INTO direct_order_financials(request_id,restaurant_id,order_id,payment_id,quote_id,
 approved_by,menu_total,service_charge_total,delivery_fee_total,final_total)
SELECT kds_test.id(800030),'8bc9eef5-dcd5-46b1-b931-23f77132322c',oi.order_id,kds_test.id(800033),
 kds_test.id(800034),kds_test.id(900011),1,0,0,1 FROM order_items oi WHERE oi.notes='fixture note';
INSERT INTO direct_order_customer_requirements(id,request_id,restaurant_id,source_kind,source_id,
 source_locale,request_text,status,print_scope,item_label_vi,print_reply_vi)
VALUES(kds_test.id(800035),kds_test.id(800030),'8bc9eef5-dcd5-46b1-b931-23f77132322c','order',
 kds_test.id(800030),'vi','Fixture request','confirmed','preparation','Món','Ghi chú');

CREATE FUNCTION kds_test.normalized_orders(p jsonb) RETURNS jsonb LANGUAGE sql AS $$
 SELECT coalesce(jsonb_agg((o-'oldest_tray_ready_sequence')||jsonb_build_object('items',
  coalesce((SELECT jsonb_agg(i-'oldest_tray_ready_sequence' ORDER BY n)
   FROM jsonb_array_elements(o->'items') WITH ORDINALITY a(i,n)),'[]')) ORDER BY o->>'queue_id'),'[]')
 FROM jsonb_array_elements(p)o;
$$;

INSERT INTO leftover_packaging_requests(id,restaurant_id,session_id,order_id,queue_id,table_number,floor_label,source,status)
SELECT kds_test.id(800100+n),'8bc9eef5-dcd5-46b1-b931-23f77132322c',q.session_id,q.order_id,q.id,q.table_number,
 q.floor_label,'staff',(ARRAY['awaiting_floor_pickup','awaiting_tray_to_kitchen','awaiting_kitchen_packaging','awaiting_tray_return','awaiting_floor_delivery'])[n]
FROM generate_series(1,5)n CROSS JOIN LATERAL (
 SELECT * FROM emergency_order_queue WHERE created_at>=date_trunc('day',now()) AND floor_label='1F' ORDER BY id LIMIT 1 OFFSET (n-1)
)q;

DO $test$
DECLARE role_number int; original jsonb; combined jsonb; page jsonb; cursor_value jsonb;
 seen uuid[]; ident uuid; expected jsonb; rounds int; raw jsonb;
BEGIN
 FOR role_number IN SELECT unnest(ARRAY[1,2,3,5]) LOOP
  PERFORM set_config('request.jwt.claim.sub',kds_test.id(900020+role_number)::text,true);
  SELECT coalesce(jsonb_agg(o ORDER BY o->>'queue_id'),'[]') INTO original
  FROM jsonb_array_elements(public.get_emergency_station_today_completed_base_pre_bunsik())o
  WHERE (o->>'created_at')::timestamptz>=date_trunc('day',now());
  combined:='[]';cursor_value:=NULL;seen:='{}';rounds:=0;
  LOOP
   page:=public.bunsik_kds_completed_core_v1(50,(cursor_value->>'completed_at')::timestamptz,
    (cursor_value->>'queue_id')::uuid);
   IF jsonb_array_length(page->'orders')>50 THEN RAISE EXCEPTION 'PAGE_TOO_LARGE'; END IF;
   FOR ident IN SELECT (o->>'queue_id')::uuid FROM jsonb_array_elements(page->'orders')o LOOP
    IF ident=ANY(seen) THEN RAISE EXCEPTION 'DUPLICATE_CURSOR_ROW'; END IF;
    seen:=array_append(seen,ident);
   END LOOP;
   combined:=combined||(page->'orders');rounds:=rounds+1;
   EXIT WHEN NOT (page->>'has_more')::boolean;
   IF rounds>20 OR page->'next_cursor' IS NULL THEN RAISE EXCEPTION 'CURSOR_DID_NOT_ADVANCE'; END IF;
   cursor_value:=page->'next_cursor';
  END LOOP;
  SELECT coalesce(jsonb_agg(o ORDER BY o->>'queue_id'),'[]') INTO expected FROM jsonb_array_elements(combined)o;
  IF expected<>original THEN RAISE EXCEPTION 'BASE_PARITY_FAILED station=%',role_number; END IF;
  raw:=public.bunsik_kds_completed_core_v1(50)->'orders';
  IF public.bunsik_kds_batch_timings_v1(raw)<>public.emergency_add_order_batch_timings_pre_bunsik(raw)
  THEN RAISE EXCEPTION 'BATCH_TIMINGS_PARITY_FAILED'; END IF;
  page:=public.get_bunsik_kds_completed_page_v1();
  IF jsonb_array_length(page->'orders')>50 THEN RAISE EXCEPTION 'PUBLIC_PAGE_TOO_LARGE'; END IF;
  -- The complete-schema run verifies the actual live wrapper contracts.
  IF to_regprocedure('public.get_emergency_station_snapshot_base()') IS NOT NULL THEN
   IF kds_test.normalized_orders(public.get_emergency_station_snapshot()->'orders')
    <>kds_test.normalized_orders(public.get_emergency_station_snapshot_pre_bunsik()->'orders')
   THEN RAISE EXCEPTION 'SNAPSHOT_METADATA_PARITY_FAILED station=%',role_number; END IF;
   IF public.get_emergency_station_snapshot()-'orders'
    <>public.get_emergency_station_snapshot_pre_bunsik()-'orders'
   THEN RAISE EXCEPTION 'SNAPSHOT_HEADER_OR_PACKAGING_CHANGED station=%',role_number; END IF;
   IF jsonb_array_length(public.get_emergency_station_today_completed())>100
   THEN RAISE EXCEPTION 'COMPATIBILITY_HISTORY_NOT_BOUNDED'; END IF;
  END IF;
 END LOOP;
 PERFORM set_config('request.jwt.claim.sub',kds_test.id(900023)::text,true);
 UPDATE emergency_station_assignments SET service_area_codes=ARRAY['1F','2F'] WHERE user_id=kds_test.id(900013);
 page:=public.get_bunsik_kds_completed_page_v1();
 IF NOT EXISTS(SELECT 1 FROM jsonb_array_elements(page->'orders')o WHERE o->>'floor_label'='2F')
 THEN RAISE EXCEPTION 'MULTI_AREA_ASSIGNMENT_NOT_USED'; END IF;
 BEGIN PERFORM public.get_bunsik_kds_completed_page_v1(101);
  RAISE EXCEPTION 'OVERSIZE_ACCEPTED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'KDS_HISTORY_PAGE_INVALID' THEN RAISE; END IF; END;
 BEGIN PERFORM public.get_bunsik_kds_completed_page_v1(50,now(),NULL);
  RAISE EXCEPTION 'PARTIAL_CURSOR_ACCEPTED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'KDS_HISTORY_PAGE_INVALID' THEN RAISE; END IF; END;
 PERFORM set_config('request.jwt.claim.sub',kds_test.id(900024)::text,true);
 BEGIN PERFORM public.get_bunsik_kds_completed_page_v1();
  RAISE EXCEPTION 'OTHER_STORE_ACCEPTED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'BUNSIK_KDS_SCOPE_REQUIRED' THEN RAISE; END IF; END;
 IF public.get_emergency_station_today_completed_base()<>public.get_emergency_station_today_completed_base_pre_bunsik()
 THEN RAISE EXCEPTION 'OTHER_STORE_COMPATIBILITY_CHANGED'; END IF;
 PERFORM set_config('request.jwt.claim.sub','',true);
 BEGIN PERFORM public.get_bunsik_kds_completed_page_v1();
  RAISE EXCEPTION 'UNAUTHENTICATED_ACCEPTED';
 EXCEPTION WHEN raise_exception THEN IF SQLERRM<>'EMERGENCY_USER_REQUIRED' THEN RAISE; END IF; END;
END $test$;
ROLLBACK;
SELECT 'BUNSIK_KDS_HISTORY=PASS pagination_ties_parity_floor_scope_bounds_privileges';
