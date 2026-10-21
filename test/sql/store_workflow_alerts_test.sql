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
 INSERT INTO public.emergency_web_push_devices(restaurant_id,user_id,station_assignment_id,token) SELECT shop,a.user_id,a.id,'fixture-workflow-token-'||a.user_id FROM public.emergency_station_assignments a WHERE a.restaurant_id=shop AND a.station_type='kitchen' AND a.is_active;
 o:=public.create_order(shop,tab,jsonb_build_array(jsonb_build_object('menu_item_id',m,'quantity',3)));
 ASSERT o.operating_release_id=release;
 ASSERT (SELECT count(*)=1 FROM public.emergency_push_deliveries WHERE order_id=o.id AND station_type='kitchen'),'initial routed push fanout wrong';
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_push_deliveries p JOIN public.emergency_web_push_devices d ON d.id=p.device_id WHERE p.order_id=o.id AND d.user_id=u2),'second kitchen notified before ready';
 SELECT id INTO oi FROM public.order_items WHERE order_id=o.id;
 SELECT s.id INTO s1 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_item_id=oi AND s.position=1;
 SELECT s.id INTO s2 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_item_id=oi AND s.position=2;
 ASSERT s1 IS NOT NULL AND s2 IS NOT NULL,'missing steps';
 SELECT id,queue_id INTO legacy,q FROM public.emergency_fulfillment_items WHERE order_item_id=oi;
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'deactivate',4); RAISE EXCEPTION 'UNDRAINED_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_DRAIN_REQUIRED'; END;
 PERFORM set_config('request.jwt.claim.sub',a2::text,true);
 BEGIN PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'start',jsonb_build_array(jsonb_build_object('step_id',s2,'revision',0,'quantity',1))); RAISE EXCEPTION 'EARLY_SECOND_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_PROGRESS_CHANGED'; END;
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000001',true);
 BEGIN PERFORM public.kds_complete_kitchen_batch_v1(gen_random_uuid(),jsonb_build_array(jsonb_build_object('item_id',legacy,'queue_id',q,'source_kind','base','quantity',1))); RAISE EXCEPTION 'LEGACY_BYPASS'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_CLIENT_UPDATE_REQUIRED'; END;
 allocations:=jsonb_build_array(jsonb_build_object('step_id',s1,'revision',0,'quantity',2));
 r:=public.store_preparation_progress_v1(shop,event,'start',allocations);
 ASSERT r=public.store_preparation_progress_v1(shop,event,'start',allocations);
 ASSERT (SELECT kitchen_started_quantity=2 AND kitchen_done_quantity=0 FROM public.emergency_fulfillment_items WHERE id=legacy);
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'done',jsonb_build_array(jsonb_build_object('step_id',s1,'revision',1,'quantity',2)));
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_floor_ready_lots WHERE order_item_id=oi),'intermediate step alerted floor';
 ASSERT (SELECT count(*)=1 FROM public.emergency_push_deliveries p JOIN public.emergency_web_push_devices d ON d.id=p.device_id WHERE p.order_id=o.id AND d.user_id=u2),'second kitchen did not receive ready push';
 PERFORM set_config('request.jwt.claim.sub',a2::text,true);
 snapshot:=public.store_preparation_snapshot_v1(shop); ASSERT jsonb_array_length(snapshot->'items')=1;
 ASSERT (snapshot->'items'->0->>'available')::int=2;
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'start',jsonb_build_array(jsonb_build_object('step_id',s2,'revision',0,'quantity',2)));
 event:=gen_random_uuid(); allocations:=jsonb_build_array(jsonb_build_object('step_id',s2,'revision',1,'quantity',1));
 r:=public.store_preparation_progress_v1(shop,event,'done',allocations); PERFORM public.store_preparation_progress_v1(shop,event,'done',allocations);
 ASSERT (SELECT sum(ready_quantity)=1 FROM public.emergency_floor_ready_lots WHERE order_item_id=oi),'final partial handoff duplicated';
 ASSERT (SELECT kitchen_done_quantity=1 AND tray_dispatched_quantity=1 FROM public.emergency_fulfillment_items WHERE id=legacy);
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000003',true);
 PERFORM public.kds_complete_customer_delivery_batch_v1(gen_random_uuid(),jsonb_build_array(jsonb_build_object('item_id',legacy,'queue_id',q,'source_kind','base','quantity',1)));
 ASSERT (SELECT floor_served_quantity=1 FROM public.emergency_fulfillment_items WHERE id=legacy),'existing floor service broke';
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000001',true);
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'start',jsonb_build_array(jsonb_build_object('step_id',s1,'revision',2,'quantity',1)));
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'done',jsonb_build_array(jsonb_build_object('step_id',s1,'revision',3,'quantity',1)));
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
 operation:=gen_random_uuid();
 r:=public.cashier_cancel_item_quantity(shop,oi,3,2,operation,'fixture cancellation');
 ASSERT (SELECT started=2 AND done=2 FROM public.store_preparation_steps WHERE id=s1),'cancel did not resize intermediate stage';
 ASSERT (SELECT cancelled_consumed_quantity=1 FROM public.order_items WHERE id=oi),'cooked cancellation consumption lost';
 PERFORM public.cashier_restore_item_quantity(shop,operation);
 ASSERT (SELECT started=3 AND done=3 FROM public.store_preparation_steps WHERE id=s1),'restore did not restore intermediate stage';
 ASSERT (SELECT quantity=3 FROM public.order_items WHERE id=oi),'partial restore failed';
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(shop,'1982','3F') RETURNING id INTO target_table;
 operation:=gen_random_uuid();
 r:=public.cashier_move_order_items(shop,o.id,target_table,jsonb_build_array(jsonb_build_object('item_id',oi,'quantity',1,'expected_quantity',3)),operation);
 ASSERT r=public.cashier_move_order_items(shop,o.id,target_table,jsonb_build_array(jsonb_build_object('item_id',oi,'quantity',1,'expected_quantity',3)),operation),'move retry changed';
 moved:=(r->'moved'->0->>'target_item_id')::uuid;
 ASSERT (SELECT quantity=1 FROM public.order_items WHERE id=moved);
 ASSERT (SELECT quantity=2 FROM public.order_items WHERE id=oi);
 ASSERT (SELECT count(*)=2 AND sum(started)=2 AND sum(done)=2 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_item_id=moved),'split stages lost';
 ASSERT (SELECT count(*)=2 AND sum(started)=3 AND sum(done)=2 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_item_id=oi),'source stages duplicated';
 ASSERT (SELECT sum(ready_quantity)=1 AND sum(served_quantity)=1 FROM public.emergency_floor_ready_lots WHERE order_item_id=moved),'split FIFO serving lost';
 ASSERT (SELECT bool_and(operating_release_id=release) FROM public.orders WHERE id IN(o.id,(r->>'target_order_id')::uuid)),'split version changed';

END $$;
SELECT 'MULTI_KITCHEN_ROUTED_ALERTS_AND_PROGRESS=PASS';
ROLLBACK;
