\set ON_ERROR_STOP on
BEGIN;
DO $$ DECLARE store_id constant uuid:='94000000-0000-4000-8000-000000000001';
 menu uuid; tid uuid; oid uuid; oi uuid; line uuid; queue uuid; response jsonb;
BEGIN
 ASSERT EXISTS(SELECT 1 FROM auth.users WHERE email='kds-lab-1@internal.invalid');
 INSERT INTO public.restaurants(id,name,brand_id,tax_entity_id)
 SELECT store_id,'Workflow generic lab',brand_id,tax_entity_id FROM public.restaurants WHERE id='8bc9eef5-dcd5-46b1-b931-23f77132322c';
 INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at)
 SELECT ('95000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 'workflow-lab-'||n||'@internal.invalid','00000000-0000-0000-0000-000000000000','authenticated','authenticated',now() FROM generate_series(1,3) n;
 INSERT INTO public.users(id,auth_id,restaurant_id,role,full_name,fixed_account_code,account_type)
 SELECT ('96000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,
 ('95000000-0000-4000-8000-'||lpad(n::text,12,'0'))::uuid,store_id,
 CASE n WHEN 1 THEN 'super_admin' WHEN 2 THEN 'kitchen' ELSE 'emergency_station' END,'Workflow fixture '||n,
 CASE n WHEN 1 THEN NULL WHEN 2 THEN 'wflab_kit' ELSE 'wflab_floor_1f' END,
 CASE n WHEN 1 THEN 'legacy_user' WHEN 2 THEN 'device_kitchen' ELSE 'device_emergency_station' END FROM generate_series(1,3) n;
 INSERT INTO public.user_store_access(user_id,store_id,is_primary,is_active,source_type)
 SELECT id,restaurant_id,true,true,'direct' FROM public.users WHERE restaurant_id=store_id;
 PERFORM set_config('request.jwt.claims','{"sub":"95000000-0000-4000-8000-000000000001","role":"authenticated"}',true);
 INSERT INTO public.restaurant_settings(restaurant_id,fulfillment_mode,kds_workflow) VALUES(store_id,'paperless','kitchen_floor');
 INSERT INTO public.emergency_fulfillment_sessions(restaurant_id,reason) VALUES(store_id,'Workflow regression');
 ASSERT NOT public.kds_is_direct_floor_store(store_id);
 ASSERT public.kds_uses_direct_floor_workflow(store_id);
 ASSERT public.emergency_floor_label(store_id,'2F','2107')='2F';
 INSERT INTO public.tables(restaurant_id,table_number,floor_label) VALUES(store_id,'WF-1','1F') RETURNING id INTO tid;
 INSERT INTO public.menu_items(restaurant_id,name,price) VALUES(store_id,'Workflow dish',10000) RETURNING id INTO menu;
 INSERT INTO public.orders(restaurant_id,table_id,status) VALUES(store_id,tid,'pending') RETURNING id INTO oid;
 INSERT INTO public.order_items(restaurant_id,order_id,menu_item_id,display_name,quantity,unit_price,status)
 VALUES(store_id,oid,menu,'Workflow dish',1,10000,'pending') RETURNING id INTO oi;
 SELECT id,queue_id INTO line,queue FROM public.emergency_fulfillment_items WHERE order_item_id=oi;
 ASSERT (SELECT kitchen_direct_to_floor FROM public.emergency_order_queue WHERE id=queue);
 PERFORM set_config('request.jwt.claims','{"sub":"95000000-0000-4000-8000-000000000002","role":"authenticated"}',true);
 response:=public.kds_record_station_progress_v3(line,'base','kitchen_started',1,gen_random_uuid());
 ASSERT response->>'kitchen_done_quantity'='0';
 PERFORM public.kds_complete_kitchen_batch_v1(gen_random_uuid(),jsonb_build_array(jsonb_build_object('item_id',line,'queue_id',queue,'source_kind','base','quantity',1)));
 ASSERT NOT EXISTS(SELECT 1 FROM public.emergency_tray_ready_lots WHERE source_id=line);
 ASSERT EXISTS(SELECT 1 FROM public.emergency_floor_ready_lots WHERE source_id=line);
 PERFORM set_config('request.jwt.claims','{"sub":"95000000-0000-4000-8000-000000000003","role":"authenticated"}',true);
 PERFORM public.kds_record_station_progress_v3(line,'base','floor_served',1,gen_random_uuid());
 ASSERT (SELECT floor_served_quantity=1 FROM public.emergency_fulfillment_items WHERE id=line);
END $$;
ROLLBACK;
SELECT 'GENERIC_STORE_DIRECT_WORKFLOW=PASS';
