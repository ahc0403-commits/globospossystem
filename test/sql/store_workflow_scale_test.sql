BEGIN;
SET LOCAL pg_stat_statements.track='all';
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
 s1 uuid; s2 uuid; step public.store_preparation_steps; event uuid:=gen_random_uuid(); allocations jsonb; legacy uuid; q uuid; snapshot jsonb; moved uuid; target_table uuid; operation uuid; started_at timestamptz; elapsed numeric; cursor jsonb;
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

 started_at:=clock_timestamp();
 o:=public.create_order(shop,tab,(SELECT jsonb_agg(jsonb_build_object('menu_item_id',m,'quantity',1,'notes','Scale '||n)) FROM generate_series(1,500)n));
 RAISE NOTICE 'WORKFLOW_SCALE intake_500_lines_ms=%',extract(epoch FROM clock_timestamp()-started_at)*1000;
 ASSERT (SELECT count(*)=500 FROM public.store_preparation_tasks WHERE order_id=o.id);
 ASSERT (SELECT count(*)=1000 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE order_id=o.id);
 PERFORM set_config('request.jwt.claim.sub','92000000-0000-4000-8000-000000000001',true);
 started_at:=clock_timestamp();
 snapshot:=public.store_preparation_snapshot_v1(shop);
 elapsed:=extract(epoch FROM clock_timestamp()-started_at)*1000;
 ASSERT jsonb_array_length(snapshot->'items')=100 AND (snapshot->>'has_more')::boolean;
 RAISE NOTICE 'WORKFLOW_SCALE snapshot_100_rows_ms=%, response_bytes=%',elapsed,octet_length(snapshot::text);
 cursor:=snapshot->'items'->99;
 r:=public.store_preparation_snapshot_v1(shop,(cursor->>'created_at')::timestamptz,(cursor->>'id')::uuid);
 ASSERT jsonb_array_length(r->'items')=100 AND NOT EXISTS(SELECT 1 FROM jsonb_array_elements(r->'items')a JOIN jsonb_array_elements(snapshot->'items')b ON a->>'id'=b->>'id'),'keyset duplicated items';
 SELECT jsonb_agg(jsonb_build_object('step_id',s.id,'revision',s.revision,'quantity',1)) INTO allocations FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_id=o.id AND s.position=1;
 started_at:=clock_timestamp();
 PERFORM public.store_preparation_progress_v1(shop,gen_random_uuid(),'start',allocations);
 RAISE NOTICE 'WORKFLOW_SCALE batch_start_500_ms=%',extract(epoch FROM clock_timestamp()-started_at)*1000;
 ASSERT (SELECT sum(kitchen_started_quantity)=500 AND sum(kitchen_done_quantity)=0 FROM public.emergency_fulfillment_items WHERE order_id=o.id);
 ASSERT (SELECT count(*)=4 FROM realtime.kds_lab_messages WHERE topic LIKE 'workflow:'||shop||':%'),'one invalidation per station, not per line';
 ASSERT (SELECT count(*)=500 FROM public.store_preparation_steps s JOIN public.store_preparation_tasks t ON t.id=s.task_id WHERE t.order_id=o.id AND s.started=1);
END $$;
SELECT calls,rows,round(total_exec_time::numeric,3) ms,left(query,90) statement
FROM extensions.pg_stat_statements
WHERE query LIKE 'UPDATE public.store_preparation_steps s SET started=started+%'
 OR query LIKE 'WITH rows AS MATERIALIZED (%' AND query LIKE '%store_preparation_sources%'
ORDER BY query;
SELECT 'WORKFLOW_500_LINES_BOUNDED_READ_BATCH=PASS';
ROLLBACK;
