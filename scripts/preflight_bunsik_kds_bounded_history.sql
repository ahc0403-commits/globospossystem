-- Read-only production prerequisite: match the reviewed live read functions.
DO $$
BEGIN
 IF (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.get_emergency_station_today_completed()')) IS DISTINCT FROM '7248859a6a9d78b97bfa306ed2f7f63f'
 THEN RAISE EXCEPTION 'BUNSIK_KDS_PREDECESSOR_DRIFT:get_emergency_station_today_completed()'; END IF;
 IF (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.get_emergency_station_snapshot()')) IS DISTINCT FROM '93d26203a4c0b05535f97a8a3ed3866d'
 THEN RAISE EXCEPTION 'BUNSIK_KDS_PREDECESSOR_DRIFT:get_emergency_station_snapshot()'; END IF;
 IF (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.emergency_add_order_batch_timings(jsonb)')) IS DISTINCT FROM 'e3b69e94e37a881f5e09c24b613707c3'
 THEN RAISE EXCEPTION 'BUNSIK_KDS_PREDECESSOR_DRIFT:emergency_add_order_batch_timings(jsonb)'; END IF;
 IF (SELECT md5(prosrc) FROM pg_proc WHERE oid=to_regprocedure('public.get_emergency_station_today_completed_base()')) IS DISTINCT FROM '767d04eb959d8d54a9fd2abb58c091a9'
 THEN RAISE EXCEPTION 'BUNSIK_KDS_PREDECESSOR_DRIFT:get_emergency_station_today_completed_base()'; END IF;
 IF coalesce((SELECT mode FROM public.kds_realtime_rollouts WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c'),'legacy')<>'legacy'
 OR NOT EXISTS(SELECT 1 FROM public.restaurant_settings WHERE restaurant_id='8bc9eef5-dcd5-46b1-b931-23f77132322c'
  AND kds_workflow='kitchen_tray_floor' AND fulfillment_mode='paperless')
 THEN RAISE EXCEPTION 'BUNSIK_KDS_OPERATIONAL_SCOPE_CHANGED'; END IF;
END $$;
