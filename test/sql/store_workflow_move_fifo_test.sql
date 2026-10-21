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
 shop uuid:='273b057e-3b69-46e3-93c1-6194c2802849'; k1 uuid:=gen_random_uuid(); k2 uuid:=gen_random_uuid();
 a2 uuid:=gen_random_uuid(); u2 uuid:=gen_random_uuid(); definition jsonb; r jsonb; release uuid; m uuid; tab uuid; o public.orders; oi uuid;
 s1 uuid; s2 uuid; step public.store_preparation_steps; event uuid:=gen_random_uuid(); allocations jsonb; legacy uuid; q uuid; snapshot jsonb; moved uuid; target_table uuid; operation uuid;
BEGIN
 INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at) VALUES(a2,'workflow-kitchen2@internal.invalid','00000000-0000-0000-0000-000000000000','authenticated','authenticated',now());
 INSERT INTO public.users(id,auth_id,restaurant_id,role,full_name) VALUES(u2,a2,shop,'kitchen','Second kitchen');
 INSERT INTO public.emergency_station_assignments(restaurant_id,user_id,station_type,is_active) VALUES(shop,u2,'kitchen',true);
 PERFORM public.approve_invoice_mapping_policy(shop,'91000000-0000-4000-8000-000000000004','workflow-fixture','{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','isolated workflow approval');
 INSERT INTO public.menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price) VALUES(shop,'Workflow dish','Món bếp','Phần',10000) RETURNING id INTO m;
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(shop,'1981','2F') RETURNING id INTO tab;
 definition:=jsonb_build_object('schema',1,'workflow','kitchen_floor','fulfillment_mode','paperless',
  'stations',jsonb_build_array(jsonb_build_object('id',k1,'name','주방 1','user_ids',jsonb_build_array('93000000-0000-4000-8000-000000000001')),
   jsonb_build_object('id',k2,'name','주방 2','user_ids',jsonb_build_array(u2))),
  'default_path',jsonb_build_array(k1,k2),'routes','[]'::jsonb);
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
 o:=public.create_order(shop,tab,jsonb_build_array(jsonb_build_object('menu_item_id',m,'quantity',3)));
 ASSERT o.operating_release_id=release;
 SELECT id INTO oi FROM public.order_items WHERE order_id=o.id;
 SELECT s.id INTO s1 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_item_id=oi AND s.position=1;
 SELECT s.id INTO s2 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_item_id=oi AND s.position=2;
 ASSERT s1 IS NOT NULL AND s2 IS NOT NULL,'missing steps';
 SELECT id,queue_id INTO legacy,q FROM public.emergency_fulfillment_items WHERE order_item_id=oi;

 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000001',true);
 BEGIN PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),NULL,jsonb_build_array(jsonb_build_object('step_id',s1,'revision',0,'quantity',1))); RAISE EXCEPTION 'NULL_ACTION_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_INPUT_INVALID'; END;
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'start',jsonb_build_array(jsonb_build_object('step_id',s1,'revision',0,'quantity',3)));
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'undo_start',jsonb_build_array(jsonb_build_object('step_id',s1,'revision',1,'quantity',1)));
 ASSERT (SELECT started=2 AND done=0 FROM public.store_preparation_steps WHERE id=s1);
 ASSERT (SELECT kitchen_started_quantity=2 FROM public.emergency_fulfillment_items WHERE id=legacy);
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'done',jsonb_build_array(jsonb_build_object('step_id',s1,'revision',2,'quantity',2)));
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'undo_done',jsonb_build_array(jsonb_build_object('step_id',s1,'revision',3,'quantity',1)));
 ASSERT (SELECT done=1 FROM public.store_preparation_steps WHERE id=s1);
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'done',jsonb_build_array(jsonb_build_object('step_id',s1,'revision',4,'quantity',1)));
 PERFORM set_config('request.jwt.claim.sub',a2::text,true);
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'start',jsonb_build_array(jsonb_build_object('step_id',s2,'revision',0,'quantity',2)));
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000001',true);
 BEGIN PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'undo_done',jsonb_build_array(jsonb_build_object('step_id',s1,'revision',5,'quantity',1))); RAISE EXCEPTION 'DOWNSTREAM_UNDO_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_PROGRESS_CHANGED'; END;
 PERFORM set_config('request.jwt.claim.sub',a2::text,true);
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'done',jsonb_build_array(jsonb_build_object('step_id',s2,'revision',1,'quantity',2)));
 ASSERT (SELECT sum(ready_quantity-voided_quantity)=2 FROM public.emergency_floor_ready_lots WHERE order_item_id=oi);
 event:=gen_random_uuid(); allocations:=jsonb_build_array(jsonb_build_object('step_id',s2,'revision',2,'quantity',1));
 r:=public.store_preparation_progress_v1(shop,event,'undo_done',allocations);
 ASSERT r=public.store_preparation_progress_v1(shop,event,'undo_done',allocations),'undo replay changed';
 ASSERT (SELECT sum(ready_quantity-voided_quantity)=1 FROM public.emergency_floor_ready_lots WHERE order_item_id=oi),'undo did not void remaining FIFO';
 ASSERT (SELECT kitchen_done_quantity=1 AND tray_dispatched_quantity=1 FROM public.emergency_fulfillment_items WHERE id=legacy);
 ASSERT (SELECT jsonb_array_length(before_steps)=1 AND jsonb_array_length(after_steps)=1 AND before_steps->0->>'done'='2' AND after_steps->0->>'done'='1' FROM public.store_preparation_events WHERE id=event),'undo audit missing';
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'done',jsonb_build_array(jsonb_build_object('step_id',s2,'revision',3,'quantity',1)));
 ASSERT (SELECT sum(ready_quantity-voided_quantity)=2 FROM public.emergency_floor_ready_lots WHERE order_item_id=oi),'redo duplicated FIFO';

 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(shop,'1982','3F') RETURNING id INTO target_table;
 r:=public.cashier_move_order_items(shop,o.id,target_table,jsonb_build_array(jsonb_build_object('item_id',oi,'quantity',1,'expected_quantity',3)),gen_random_uuid());
 moved:=(r->'moved'->0->>'target_item_id')::uuid;
 ASSERT (SELECT sum(ready_quantity-voided_quantity)=1 FROM public.emergency_floor_ready_lots WHERE order_item_id=moved),'moved active lot missing';
 ASSERT (SELECT sum(ready_quantity-voided_quantity)=1 AND sum(voided_quantity)=1 FROM public.emergency_floor_ready_lots WHERE order_item_id=oi),'split resurrected voided units';
 r:=public.cashier_move_order_items(shop,o.id,target_table,jsonb_build_array(jsonb_build_object('item_id',oi,'quantity',2,'expected_quantity',2)),gen_random_uuid());
 ASSERT (SELECT sum(ready_quantity-voided_quantity)=2 AND sum(voided_quantity)=1 FROM public.emergency_floor_ready_lots WHERE order_id=(r->>'target_order_id')::uuid),'full move resurrected voided units';
END $$;
SELECT 'WORKFLOW_MOVE_VOIDED_FIFO=PASS';
ROLLBACK;
