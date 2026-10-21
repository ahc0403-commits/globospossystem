SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',false);
SELECT setup_assert(public.kds_uses_direct_floor_workflow('273b057e-3b69-46e3-93c1-6194c2802849'),'JeonGabok defaults to kitchen-floor');
SELECT setup_assert(NOT public.kds_uses_direct_floor_workflow('8bc9eef5-dcd5-46b1-b931-23f77132322c'),'Bunsik defaults to kitchen-tray-floor');
INSERT INTO public.emergency_order_queue(restaurant_id) VALUES('20000000-0000-4000-8000-000000000004');
SELECT admin_apply_store_opening_config_v3('20000000-0000-4000-8000-000000000004',tables,receipt,'paperless','kitchen_floor') FROM setup_inputs;
SELECT setup_assert(public.kds_uses_direct_floor_workflow('20000000-0000-4000-8000-000000000004'),'opening setup persists direct workflow');
SELECT setup_assert((SELECT NOT kitchen_direct_to_floor FROM public.emergency_order_queue WHERE restaurant_id='20000000-0000-4000-8000-000000000004'),'existing queue snapshot preserved');
INSERT INTO public.emergency_order_queue(restaurant_id) VALUES('20000000-0000-4000-8000-000000000004');
SELECT setup_assert((SELECT count(*) FILTER(WHERE kitchen_direct_to_floor)=1 FROM public.emergency_order_queue WHERE restaurant_id='20000000-0000-4000-8000-000000000004'),'new queue uses configured workflow');
INSERT INTO public.orders(restaurant_id,status) VALUES('20000000-0000-4000-8000-000000000004','pending');
DO $$ BEGIN
 PERFORM setup_assert(public.kds_store_workflow_errors('20000000-0000-4000-8000-000000000004','kitchen_tray_floor')='["STORE_SETUP_WORKFLOW_BUSY"]','open orders block workflow change');
 BEGIN
  UPDATE public.restaurant_settings SET kds_workflow='kitchen_tray_floor' WHERE restaurant_id='20000000-0000-4000-8000-000000000004';
  RAISE EXCEPTION 'unguarded direct update';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'STORE_SETUP_CONFIG_INVALID' THEN RAISE; END IF; END;
 PERFORM setup_assert(public.kds_store_workflow_errors('273b057e-3b69-46e3-93c1-6194c2802849','kitchen_tray_floor')='["STORE_SETUP_WORKFLOW_JEONGABOK"]','retired JeonGabok checker stays retired');
END $$;
UPDATE public.orders SET status='completed';
SELECT admin_apply_store_opening_config_v3('20000000-0000-4000-8000-000000000004',tables,receipt,'paperless','kitchen_tray_floor') FROM setup_inputs;
SELECT setup_assert(NOT public.kds_uses_direct_floor_workflow('20000000-0000-4000-8000-000000000004'),'drained store can return to tray workflow');
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000002',false);
DO $$ BEGIN
 PERFORM setup_assert(public.kds_store_workflow_errors('20000000-0000-4000-8000-000000000001','kitchen_floor')='["STORE_SETUP_WORKFLOW_PERMISSION"]','store admin cannot change owner workflow');
 BEGIN
  PERFORM public.admin_apply_store_opening_config_v3('20000000-0000-4000-8000-000000000002','[]','[]','paperless','kitchen_floor');
  RAISE EXCEPTION 'cross tenant allowed';
 EXCEPTION WHEN OTHERS THEN IF SQLERRM<>'ADMIN_MUTATION_FORBIDDEN' THEN RAISE; END IF; END;
END $$;
SELECT set_config('request.jwt.claim.sub','10000000-0000-4000-8000-000000000001',false);
INSERT INTO public.emergency_order_queue(restaurant_id) SELECT CASE WHEN n%2=0 THEN '273b057e-3b69-46e3-93c1-6194c2802849'::uuid ELSE '8bc9eef5-dcd5-46b1-b931-23f77132322c'::uuid END FROM generate_series(1,500) n;
SELECT pg_stat_statements_reset();
SELECT setup_assert(jsonb_array_length(public.emergency_add_order_batch_timings('[]'))=502,'500-row workflow reader');
SELECT setup_assert(coalesce((SELECT sum(calls)=1 FROM pg_stat_statements WHERE query LIKE '%array_agg(restaurant_id)%' AND query NOT LIKE '%pg_stat_statements%'),false),'workflow configuration read once for 500 queue rows');
SELECT calls,rows,total_exec_time FROM pg_stat_statements WHERE query LIKE '%array_agg(restaurant_id)%' AND query NOT LIKE '%pg_stat_statements%';
SELECT pg_stat_statements_reset();
SELECT public.kds_uses_direct_floor_workflow('273b057e-3b69-46e3-93c1-6194c2802849');
INSERT INTO public.workflow_fixture_events(restaurant_id,queue_id,stage,details)
 SELECT q.restaurant_id,q.id,'kitchen_done',jsonb_build_object('kitchen_direct_to_floor',q.kitchen_direct_to_floor)
 FROM public.emergency_order_queue q WHERE restaurant_id IN ('273b057e-3b69-46e3-93c1-6194c2802849','8bc9eef5-dcd5-46b1-b931-23f77132322c') LIMIT 500;
SELECT setup_assert((SELECT count(*)=500 FROM public.workflow_fixture_changes),'500 event snapshots delivered');
SELECT setup_assert((SELECT count(*) FILTER(WHERE direct)=250 FROM public.workflow_fixture_deliveries),'broadcast respects mixed store snapshots');
SELECT setup_assert(coalesce((SELECT sum(calls)=1 FROM pg_stat_statements WHERE query LIKE '%array_agg(restaurant_id)%' AND query NOT LIKE '%pg_stat_statements%'),false),'500 event triggers reuse snapshots with no configuration lookups per item');
SELECT setup_assert(NOT has_function_privilege('authenticated','public.kds_direct_floor_store_ids()','EXECUTE'),'internal configuration IDs are not exposed as an RPC');
SELECT 'STORE_KDS_WORKFLOW_SQL=PASS';
