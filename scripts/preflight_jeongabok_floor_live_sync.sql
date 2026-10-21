DO $$ BEGIN
 IF NOT public.kds_is_direct_floor_store('273b057e-3b69-46e3-93c1-6194c2802849')
 OR to_regprocedure('public.kds_direct_filter_targets()') IS NULL
 OR to_regprocedure('public.get_kds_bootstrap_v2()') IS NULL
 THEN RAISE EXCEPTION 'DIRECT_FLOOR_LIVE_SYNC_PREREQUISITES_MISSING'; END IF;
END $$;
SELECT 'JEONGABOK_FLOOR_LIVE_SYNC_PREFLIGHT=PASS';
