DO $$ BEGIN
 IF NOT EXISTS(SELECT 1 FROM public.kds_realtime_rollouts WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND mode='active')
 OR position('kds_is_direct_floor_store' IN pg_get_functiondef('public.kds_capture_fulfillment_event()'::regprocedure))=0
 OR EXISTS(SELECT 1 FROM public.emergency_station_assignments WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND station_type='tray' AND is_active)
 THEN RAISE EXCEPTION 'DIRECT_FLOOR_LIVE_SYNC_VERIFY_FAILED'; END IF;
END $$;
SELECT 'JEONGABOK_FLOOR_LIVE_SYNC_VERIFY=PASS';
