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
 s1 uuid; s2 uuid; step public.store_preparation_steps; event uuid:=gen_random_uuid(); allocations jsonb; legacy uuid; q uuid; snapshot jsonb; moved uuid; target_table uuid; operation uuid; bad jsonb; device uuid; old_order uuid;
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

 bad:=jsonb_set(definition,'{default_path}',jsonb_build_array(k1,k1));
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'save',0,bad); RAISE EXCEPTION 'CYCLE_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_PATH_INVALID'; END;
 bad:=jsonb_set(definition,'{stations,0,user_ids}',jsonb_build_array('93000000-0000-4000-8000-000000000006'));
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'save',0,bad); RAISE EXCEPTION 'OTHER_STORE_ACTOR_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_ASSIGNMENT_INVALID'; END;
 bad:=definition-'schema';
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'save',0,bad); RAISE EXCEPTION 'NO_SCHEMA_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_DEFINITION_INVALID'; END;
 bad:=jsonb_set(definition,'{routes}',jsonb_build_array(jsonb_build_object('menu_ids',jsonb_build_array(m,m),'channels',jsonb_build_array('pickup'),'path',jsonb_build_array(k2))));
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'save',0,bad); RAISE EXCEPTION 'DUP_ROUTE_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_ROUTE_INVALID'; END;
 bad:=jsonb_set(definition,'{routes}',jsonb_build_array(jsonb_build_object('menu_ids',jsonb_build_array(m),'channels',jsonb_build_array('pickup'),'path',jsonb_build_array(k2))));
 ASSERT public.store_workflow_path(bad,gen_random_uuid(),'takeaway',m)=jsonb_build_array(k2),'parent or takeaway routing failed';
 ASSERT public.store_workflow_path(bad,m,'dine_in')=jsonb_build_array(k1,k2),'channel override escaped';
 r:=public.admin_store_workflow_v1(shop,'save',0,definition);
 ASSERT (r->>'revision')::int=1;
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'save',0,definition); RAISE EXCEPTION 'STALE_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_CHANGED'; END;
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'publish',1); RAISE EXCEPTION 'UNVALIDATED_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_REVALIDATE'; END;
 r:=public.admin_store_workflow_v1(shop,'validate',1); ASSERT (r->'proof'->>'channel_cases')::int>0;
 UPDATE public.menu_items SET price=10001 WHERE id=m;
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'publish',2); RAISE EXCEPTION 'STALE_PROOF_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_REVALIDATE'; END;
 UPDATE public.menu_items SET price=10000 WHERE id=m;
 r:=public.admin_store_workflow_v1(shop,'publish',2); release:=(r->>'candidate_id')::uuid;
 ASSERT (r->>'active_id') IS NULL,'publish switched live orders';
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'activate',3); RAISE EXCEPTION 'UNREADY_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_DEVICES_NOT_READY'; END;
 o:=public.create_order(shop,tab,jsonb_build_array(jsonb_build_object('menu_item_id',m,'quantity',1)));
 SELECT id INTO oi FROM public.order_items WHERE order_id=o.id;
 SELECT id,queue_id INTO legacy,q FROM public.emergency_fulfillment_items WHERE order_item_id=oi;
 -- Actual actor acknowledgements for each required fixture account.
 FOR snapshot IN SELECT to_jsonb(u) FROM public.emergency_station_assignments a JOIN public.users u ON u.id=a.user_id WHERE a.restaurant_id=shop AND a.is_active LOOP
  PERFORM set_config('request.jwt.claim.sub',snapshot->>'auth_id',true);
  PERFORM public.store_workflow_device_v1(shop,gen_random_uuid(),release,0);
 END LOOP;
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000001',true);
 BEGIN PERFORM public.kds_complete_kitchen_batch_v1(gen_random_uuid(),jsonb_build_array(jsonb_build_object('item_id',legacy,'queue_id',q,'source_kind','base','quantity',1))); RAISE EXCEPTION 'QUIESCED_LEGACY_ADVANCED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_DEVICE_QUIESCED'; END;
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'activate',3); RAISE EXCEPTION 'UNDRAINED_OLD_ORDER_SWITCHED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_DRAIN_REQUIRED'; END;
 UPDATE public.order_items SET status='cancelled' WHERE id=oi;
 UPDATE public.orders SET status='cancelled' WHERE id=o.id;
 UPDATE public.emergency_fulfillment_items SET is_cancelled=true WHERE id=legacy;
 r:=public.admin_store_workflow_v1(shop,'activate',3); ASSERT r->>'active_id'=release::text;

 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000001',true);
 ASSERT public.kds_can_access_topic('workflow:'||shop||':'||k1||':'||release),'assigned topic denied';
 ASSERT NOT public.kds_can_access_topic('workflow:'||shop||':'||k2||':'||release),'other kitchen topic exposed';
 ASSERT NOT public.kds_can_access_topic('kds:'||shop||':kitchen'),'legacy shared topic exposed';
 BEGIN PERFORM public.store_preparation_snapshot_v1('8bc9eef5-dcd5-46b1-b931-23f77132322c'); RAISE EXCEPTION 'CROSS_STORE_READ'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_ACTOR_REQUIRED'; END;
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'load'); RAISE EXCEPTION 'KITCHEN_ADMIN_ACCEPTED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM<>'KITCHEN_ADMIN_ACCEPTED'; END;
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000003',true);
 ASSERT public.kds_can_access_topic('kds:'||shop||':floor:2F');
 ASSERT NOT public.kds_can_access_topic('kds:'||shop||':floor:3F');
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
 SELECT device_id INTO device FROM public.store_workflow_devices WHERE restaurant_id=shop AND user_id='93000000-0000-4000-8000-000000000001';
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'retire_device',4,jsonb_build_object('user_id','93000000-0000-4000-8000-000000000001','device_id',device)); RAISE EXCEPTION 'LIVE_DEVICE_REMOVED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_DEVICE_NOT_RETIRABLE'; END;
 UPDATE public.store_workflow_devices SET seen_at=now()-interval '6 minutes',pending_count=1 WHERE device_id=device;
 BEGIN PERFORM public.admin_store_workflow_v1(shop,'retire_device',4,jsonb_build_object('user_id','93000000-0000-4000-8000-000000000001','device_id',device)); RAISE EXCEPTION 'PENDING_DEVICE_REMOVED'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_DEVICE_NOT_RETIRABLE'; END;
 UPDATE public.store_workflow_devices SET pending_count=0 WHERE device_id=device;
 r:=public.admin_store_workflow_v1(shop,'retire_device',4,jsonb_build_object('user_id','93000000-0000-4000-8000-000000000001','device_id',device));
 ASSERT (r->>'revision')::int=5 AND NOT EXISTS(SELECT 1 FROM public.store_workflow_devices WHERE device_id=device);
 ASSERT EXISTS(SELECT 1 FROM public.audit_logs WHERE action='store_workflow_retire_device' AND entity_id=shop AND details->'proof'->>'device_id'=device::text),'retirement audit missing';
 INSERT INTO public.orders(restaurant_id,status) VALUES(shop,'pending') RETURNING id INTO old_order;
 BEGIN UPDATE public.orders SET operating_release_id=NULL WHERE id=old_order; RAISE EXCEPTION 'ORDER_VERSION_REWRITTEN'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='WORKFLOW_VERSION_IMMUTABLE'; END;
 UPDATE public.orders SET status='cancelled' WHERE id=old_order;
 r:=public.admin_store_workflow_v1(shop,'deactivate',5);
 ASSERT r->>'active_id' IS NULL AND (r->>'revision')::int=6;
 ASSERT (SELECT operating_release_id=release FROM public.orders WHERE id=old_order),'rollback changed order history';
 INSERT INTO public.orders(restaurant_id,status) VALUES(shop,'pending') RETURNING * INTO o;
 ASSERT o.operating_release_id IS NULL,'legacy intake did not resume';
 ASSERT NOT has_function_privilege('anon','public.admin_store_workflow_v1(uuid,text,bigint,jsonb)','EXECUTE');
 ASSERT NOT has_table_privilege('authenticated','public.store_preparation_steps','SELECT');
 ASSERT NOT has_function_privilege('authenticated','public.store_workflow_validate(uuid,jsonb)','EXECUTE');
END $$;
SELECT 'WORKFLOW_SECURITY_PUBLICATION_ROLLBACK=PASS';
ROLLBACK;
