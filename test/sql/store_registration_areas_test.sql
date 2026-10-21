-- Real schema, real onboarding worker reconciliation and real KDS mutations.
BEGIN;
ALTER TABLE auth.users ADD COLUMN IF NOT EXISTS is_sso_user boolean NOT NULL DEFAULT false;
SELECT set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
UPDATE public.brands SET short_code='LAB' WHERE id='91000000-0000-4000-8000-000000000003';
DO $$ DECLARE
 request uuid:=gen_random_uuid(); shop uuid; pickup uuid; multi uuid; input jsonb; preview jsonb; lease jsonb; result jsonb;
 brand uuid:='91000000-0000-4000-8000-000000000003'; entity uuid:='91000000-0000-4000-8000-000000000004';
 kit uuid; hall uuid; tab uuid; menu uuid; ord public.orders; line uuid; item uuid; queue uuid; allocation jsonb; code text; started timestamptz:=clock_timestamp();
BEGIN
 input:=jsonb_build_object('name','Single floor restaurant','brand',brand,'entity',entity);
 preview:=public.admin_preview_store_registration_v1(request,brand);
 code:=preview->>'code';
 ASSERT code ~ '^ST[0-9]{4}$';
 ASSERT preview->'config'->'areas'->0->>'physical_floor' IS NULL;
 ASSERT jsonb_array_length(preview->'accounts')=6,'unexpected unnecessary devices';
 ASSERT NOT EXISTS(SELECT 1 FROM jsonb_array_elements(preview->'accounts')a WHERE a->>'account_code' ~ 'tray|floor_|_order$|_print$');
 ASSERT public.admin_preview_store_registration_v1(request,brand)->>'code'=code;
 shop:=public.admin_register_store_v1(request,input);
 ASSERT public.admin_register_store_v1(request,input)=shop,'retry duplicated store';
 ASSERT (SELECT count(*)=1 FROM store_account_onboarding_jobs WHERE id=request);
 ASSERT (SELECT count(*)=1 FROM store_service_areas WHERE restaurant_id=shop AND stored_code='HALL' AND physical_floor IS NULL);
 BEGIN PERFORM public.admin_register_store_v1(request,input||'{"name":"changed"}'); RAISE EXCEPTION 'changed replay accepted'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='REQUEST_CONFLICT',SQLERRM; END;
 BEGIN PERFORM public.admin_reserve_store_code_v1(gen_random_uuid(),code); RAISE EXCEPTION 'duplicate code accepted'; EXCEPTION WHEN raise_exception THEN ASSERT SQLERRM='ABBREVIATION_EXISTS',SQLERRM; END;

 lease:=public.claim_store_onboarding_v1(request);
 INSERT INTO auth.users(id,email,instance_id,aud,role,email_confirmed_at,raw_app_meta_data)
 SELECT gen_random_uuid(),a->>'account_code'||'@globos.world','00000000-0000-0000-0000-000000000000','authenticated','authenticated',now(),
 jsonb_build_object('store_onboarding',jsonb_build_object('code',a->>'account_code','role',a->>'role','type',a->>'account_type','scope',a->>'scope','owner_id',a->>'owner_id'))
 FROM jsonb_array_elements(lease->'items')a WHERE NOT (a->>'auth_exists')::boolean;
 result:=public.finish_store_onboarding_v1(request,(lease->>'lease_id')::uuid);
 ASSERT result->>'status'='complete',result::text;
 SELECT u.auth_id INTO kit FROM users u JOIN emergency_station_assignments a ON a.user_id=u.id WHERE a.restaurant_id=shop AND a.station_type='kitchen';
 SELECT u.auth_id INTO hall FROM users u JOIN emergency_station_assignments a ON a.user_id=u.id WHERE a.restaurant_id=shop AND a.station_type='floor' AND a.floor_label='HALL';
 ASSERT kit IS NOT NULL AND hall IS NOT NULL,'explicit station assignment missing';
 -- Editing a profile must not remap a new direct-to-hall store to stored 2F.
 UPDATE users SET full_name=full_name||' updated' WHERE auth_id=hall;
 ASSERT (SELECT a.floor_label='HALL' FROM emergency_station_assignments a JOIN users u ON u.id=a.user_id WHERE u.auth_id=hall);
 ASSERT public.emergency_floor_label(shop,'HALL','101')='HALL';
 INSERT INTO emergency_fulfillment_sessions(restaurant_id,reason) VALUES(shop,'Single-floor regression') ON CONFLICT DO NOTHING;
 INSERT INTO kds_realtime_rollouts(restaurant_id,mode) VALUES(shop,'active') ON CONFLICT(restaurant_id) DO UPDATE SET mode='active';
 INSERT INTO tables(restaurant_id,table_number,floor_label) VALUES(shop,'101','HALL') RETURNING id INTO tab;
 PERFORM public.approve_invoice_mapping_policy(shop,entity,'operating-fixture','{"category_units":{},"menu_units":{},"combo_unit":"Phần"}','isolated fixture');
 INSERT INTO menu_items(restaurant_id,name,name_vi,invoice_sale_unit,price) VALUES(shop,'Hall meal','Món thử','Phần',10000) RETURNING id INTO menu;
 ord:=public.create_order(shop,tab,jsonb_build_array(jsonb_build_object('menu_item_id',menu,'quantity',2)));
 SELECT id INTO line FROM order_items WHERE order_id=ord.id;
 SELECT id,queue_id INTO item,queue FROM emergency_fulfillment_items WHERE order_item_id=line;
 ASSERT item IS NOT NULL,'new area did not enter KDS';
 ASSERT (SELECT floor_label='HALL' AND kitchen_direct_to_floor FROM emergency_order_queue WHERE id=queue);
 allocation:=jsonb_build_array(jsonb_build_object('item_id',item,'queue_id',queue,'source_kind','base','quantity',2));
 PERFORM set_config('request.jwt.claim.sub',kit::text,true);
 PERFORM public.kds_record_station_progress_v3(item,'base','kitchen_started',1,gen_random_uuid());
 ASSERT (SELECT kitchen_done_quantity=0 AND floor_served_quantity=0 FROM emergency_fulfillment_items WHERE id=item);
 PERFORM public.kds_complete_kitchen_batch_v1(gen_random_uuid(),allocation);
 ASSERT (SELECT kitchen_done_quantity=2 AND floor_served_quantity=0 FROM emergency_fulfillment_items WHERE id=item),'cooking auto-served';
 PERFORM set_config('request.jwt.claim.sub',hall::text,true);
 ASSERT public.kds_can_access_topic('kds:'||shop||':floor:HALL');
 ASSERT NOT public.kds_can_access_topic('kds:'||shop||':floor:1F');
 PERFORM public.kds_complete_customer_delivery_batch_v1(gen_random_uuid(),allocation);
 ASSERT (SELECT floor_served_quantity=2 FROM emergency_fulfillment_items WHERE id=item);
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000099',true);
 pickup:=public.admin_register_store_v1(gen_random_uuid(),input||jsonb_build_object('name','Pickup','config',jsonb_build_object('dine_in',false)));
 ASSERT NOT EXISTS(SELECT 1 FROM store_service_areas WHERE restaurant_id=pickup);
 ASSERT NOT EXISTS(SELECT 1 FROM store_fixed_account_requirements WHERE store_id=pickup AND account_type='device_emergency_station');
 multi:=public.admin_register_store_v1(gen_random_uuid(),input||jsonb_build_object('name','Two kitchens and areas','config','{"kitchens":2,"tray":true,"areas":[{"code":"A","name":"Hall A"},{"code":"B","name":"Hall B"}]}'::jsonb));
 ASSERT (SELECT count(*)=5 FROM store_service_stations WHERE restaurant_id=multi);
 ASSERT (SELECT count(*)=2 FROM store_fixed_account_requirements WHERE store_id=multi AND account_type='device_kitchen');
 ASSERT (SELECT count(*)=2 FROM store_service_areas WHERE restaurant_id=multi AND physical_floor IS NULL);
 -- Legacy RPCs create a durable job too, and the slug-based retry is stable.
 shop:=(public.admin_create_restaurant_v2('Legacy','legacy-restaurant','standard',entity,brand)).id;
 ASSERT (public.admin_create_restaurant_v2('Legacy','legacy-restaurant','standard',entity,brand)).id=shop;
 ASSERT EXISTS(SELECT 1 FROM store_account_onboarding_jobs WHERE store_id=shop);
 shop:=public.admin_create_store_onboarding_v1(gen_random_uuid(),'Legacy floors','','LG03',brand,entity,ARRAY['1F','2F','3F']);
 ASSERT (SELECT count(*)=3 FROM store_service_areas WHERE restaurant_id=shop);
 RAISE NOTICE 'REGISTRATION_METRICS elapsed_ms=% accounts=% preview_bytes=%',round(extract(epoch FROM clock_timestamp()-started)*1000),jsonb_array_length(preview->'accounts'),octet_length(preview::text);
END $$;
SELECT 'STORE_REGISTRATION_AREAS=PASS';
ROLLBACK;
