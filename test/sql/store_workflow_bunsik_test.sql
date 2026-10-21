BEGIN;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
-- Earlier upgrade fixtures deliberately retain pre-upgrade requests. Drain those
-- synthetic records inside this rolled-back test transaction.
UPDATE public.direct_order_requests SET state='cancelled';
UPDATE public.direct_delivery_fulfillment_tickets SET status='cancelled';
UPDATE public.order_items SET status='cancelled';
UPDATE public.orders SET status='cancelled';
UPDATE public.emergency_fulfillment_items SET is_cancelled=true;
UPDATE public.emergency_combo_component_items SET is_cancelled=true;
DO $$ DECLARE
 shop uuid:='8bc9eef5-dcd5-46b1-b931-23f77132322c'; k1 uuid:=gen_random_uuid(); k2 uuid:=gen_random_uuid();
 a2 uuid:=gen_random_uuid(); u2 uuid:=gen_random_uuid(); definition jsonb; r jsonb; release uuid; m uuid; tab uuid; o public.orders; oi uuid;
 s1 uuid; s2 uuid; step public.store_preparation_steps; event uuid:=gen_random_uuid(); allocations jsonb; legacy uuid; q uuid; snapshot jsonb; moved uuid; target_table uuid; operation uuid; m2 uuid; combo uuid; s3 uuid; sources jsonb;
BEGIN
 INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at) VALUES(a2,'workflow-kitchen2@internal.invalid','00000000-0000-0000-0000-000000000000','authenticated','authenticated',now());
 INSERT INTO public.users(id,auth_id,restaurant_id,role,full_name) VALUES(u2,a2,shop,'kitchen','Second kitchen');
 INSERT INTO public.emergency_station_assignments(restaurant_id,user_id,station_type,is_active) VALUES(shop,u2,'kitchen',true);
 PERFORM public.approve_invoice_mapping_policy(shop,'91000000-0000-4000-8000-000000000004','workflow-fixture','{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','isolated workflow approval');
 INSERT INTO public.menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price) VALUES(shop,'Workflow dish','Món bếp','Phần',10000) RETURNING id INTO m;
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(shop,'1981','1F') RETURNING id INTO tab;
 INSERT INTO public.menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price) VALUES(shop,'Parallel dish','Món riêng','Phần',20000) RETURNING id INTO m2;
 INSERT INTO public.menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price,is_combo) VALUES(shop,'Kitchen combo','Combo bếp','Phần',30000,true) RETURNING id INTO combo;
 INSERT INTO public.menu_combo_components(restaurant_id,combo_menu_item_id,component_menu_item_id,quantity) VALUES(shop,combo,m,2),(shop,combo,m2,1);
 definition:=jsonb_build_object('schema',1,'workflow','kitchen_tray_floor','fulfillment_mode','paperless',
  'stations',jsonb_build_array(jsonb_build_object('id',k1,'name','주방 1','user_ids',jsonb_build_array('93000000-0000-4000-8000-000000000006')),
   jsonb_build_object('id',k2,'name','주방 2','user_ids',jsonb_build_array(u2))),
  'default_path',jsonb_build_array(k1,k2),'routes',jsonb_build_array(jsonb_build_object('menu_ids',jsonb_build_array(m2),'channels',jsonb_build_array('dine_in','pickup','delivery'),'path',jsonb_build_array(k2))));
 r:=public.admin_store_workflow_v1(shop,'save',0,definition);
 ASSERT (r->>'revision')::int=1;
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'save',0,definition); RAISE EXCEPTION 'STALE_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_CHANGED'; END;
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'publish',1); RAISE EXCEPTION 'UNVALIDATED_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_REVALIDATE'; END;
 r:=public.admin_store_workflow_v1(shop,'validate',1); ASSERT (r->'proof'->>'channel_cases')::int>0;
 r:=public.admin_store_workflow_v1(shop,'publish',2); release:=(r->>'candidate_id')::uuid;
 ASSERT (r->>'active_id') IS NULL,'publish switched live orders';
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'activate',3); RAISE EXCEPTION 'UNREADY_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_DEVICES_NOT_READY'; END;
 -- Actual actor acknowledgements for each required fixture account.
 FOR snapshot IN SELECT to_jsonb(u) FROM public.emergency_station_assignments a JOIN public.users u ON u.id=a.user_id WHERE a.restaurant_id=shop AND a.is_active LOOP
  PERFORM set_config('request.jwt.claim.sub',snapshot->>'auth_id',true);
  PERFORM public.store_workflow_device_v1(shop,gen_random_uuid(),release,0);
 END LOOP;
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
 r:=public.admin_store_workflow_v1(shop,'activate',3); ASSERT r->>'active_id'=release::text;

 o:=public.create_order(shop,tab,jsonb_build_array(jsonb_build_object('menu_item_id',combo,'quantity',2)));
 SELECT id INTO oi FROM public.order_items WHERE order_id=o.id;
 ASSERT (SELECT count(*)=2 FROM public.emergency_combo_component_items WHERE order_item_id=oi AND NOT is_cancelled),'combo component source missing';
 SELECT s.id INTO s1 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_item_id=oi AND t.menu_item_id=m AND s.position=1;
 SELECT s.id INTO s2 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_item_id=oi AND t.menu_item_id=m AND s.position=2;
 SELECT s.id INTO s3 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_item_id=oi AND t.menu_item_id=m2 AND s.position=1;
 ASSERT s1 IS NOT NULL AND s2 IS NOT NULL AND s3 IS NOT NULL;
 ASSERT (SELECT count(*)=3 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_item_id=oi),'combo parent duplicated into kitchen';
 PERFORM set_config('request.jwt.claim.sub',a2::text,true);
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'start',jsonb_build_array(jsonb_build_object('step_id',s3,'revision',0,'quantity',2)));
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'done',jsonb_build_array(jsonb_build_object('step_id',s3,'revision',1,'quantity',2)));
 snapshot:=public.store_preparation_snapshot_v1(shop,NULL,NULL,true);
 ASSERT jsonb_array_length(snapshot->'items')=1,'completed list missing independent route';
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_floor_ready_lots WHERE order_item_id=oi),'Bunsik skipped tray';
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000006',true);
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'start',jsonb_build_array(jsonb_build_object('step_id',s1,'revision',0,'quantity',4)));
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'done',jsonb_build_array(jsonb_build_object('step_id',s1,'revision',1,'quantity',4)));
 PERFORM set_config('request.jwt.claim.sub',a2::text,true);
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'start',jsonb_build_array(jsonb_build_object('step_id',s2,'revision',0,'quantity',4)));
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'done',jsonb_build_array(jsonb_build_object('step_id',s2,'revision',1,'quantity',4)));
 ASSERT (SELECT sum(kitchen_done_quantity)=6 AND sum(tray_dispatched_quantity)=0 FROM public.emergency_combo_component_items WHERE order_item_id=oi AND NOT is_cancelled),'component quantities incorrect';
 SELECT jsonb_agg(jsonb_build_object('item_id',id,'queue_id',queue_id,'source_kind','combo_component','quantity',ordered_quantity)) INTO sources FROM public.emergency_combo_component_items WHERE order_item_id=oi AND NOT is_cancelled;
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000007',true);
 PERFORM public.kds_dispatch_tray_floor_batch_v1(gen_random_uuid(),'1F',sources);
 PERFORM set_config('request.jwt.claim.sub',a2::text,true);
 BEGIN PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'undo_done',jsonb_build_array(jsonb_build_object('step_id',s2,'revision',2,'quantity',1))); RAISE EXCEPTION 'TRAY_ACCEPTED_UNDO'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_PROGRESS_CHANGED'; END;
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000008',true);
 PERFORM public.kds_complete_customer_delivery_batch_v1(gen_random_uuid(),sources);
 ASSERT (SELECT sum(floor_served_quantity)=6 FROM public.emergency_combo_component_items WHERE order_item_id=oi AND NOT is_cancelled),'Bunsik floor lost component units';
END $$;
SELECT 'MULTI_KITCHEN_BUNSIK_PARALLEL_COMBO=PASS';
ROLLBACK;
