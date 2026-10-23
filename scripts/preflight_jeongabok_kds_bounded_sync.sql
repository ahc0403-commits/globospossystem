DO $$ BEGIN
 IF (SELECT md5(prosrc) FROM pg_proc WHERE oid='public.get_kds_sync_config()'::regprocedure)
  IS DISTINCT FROM '86dfd05e6a5db04f6edca7966258f444' THEN RAISE EXCEPTION 'JEONGABOK_KDS_CONFIG_PREDECESSOR_DRIFT'; END IF;
 IF coalesce((SELECT mode FROM public.kds_realtime_rollouts WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849'),'legacy')<>'active' THEN
  RAISE EXCEPTION 'JEONGABOK_ACTIVE_ROLLOUT_REQUIRED'; END IF;
 IF EXISTS(SELECT 1 FROM public.emergency_station_assignments WHERE restaurant_id='273b057e-3b69-46e3-93c1-6194c2802849' AND is_active AND station_type='tray') THEN
  RAISE EXCEPTION 'JEONGABOK_RETIRED_CHECKER_CHANGED'; END IF;
END $$;
